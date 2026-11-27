use super::{
    config::{Connection, Transport as TransportKind, secret},
    oauth::{Auth, Challenge},
};
use anyhow::{Context, Result, ensure};
use futures_util::{StreamExt, stream::BoxStream};
use reqwest::{Client, StatusCode, Url, header};
use rmcp::{
    RoleClient, ServiceExt,
    model::{
        CallToolRequestParams, CallToolResult, ClientInfo, ClientJsonRpcMessage, Implementation,
        JsonObject, PaginatedRequestParams, ProtocolVersion, ServerJsonRpcMessage, Tool,
    },
    service::{ClientInitializeError, RunningService, ServiceError},
    transport::{
        DynamicTransportError, Transport,
        streamable_http_client::{
            StreamableHttpClientTransport, StreamableHttpClientTransportConfig, StreamableHttpError,
        },
    },
};
use sse_stream::{Sse, SseStream};
use std::{collections::HashSet, sync::OnceLock, time::Duration};
use uuid::Uuid;

const MAX_PAGES: usize = 1024;
const MAX_TOOLS: usize = 10000;

type Session = RunningService<RoleClient, ClientInfo>;

pub(super) async fn list(connection: &Connection, integration: Uuid) -> Result<Vec<Tool>> {
    let (mut session, auth) = connect(connection, integration).await?;
    let mut result = list_session(&session).await;
    finish(&mut session).await;
    if let (Some((auth, token)), Some(challenge)) = (
        auth,
        result
            .as_ref()
            .err()
            .and_then(|error| error.downcast_ref::<ServiceError>())
            .and_then(service_challenge),
    ) {
        // Listing is read-only. Restart pagination after obtaining new credentials.
        let endpoint = connection.validate()?;
        let token = auth.token(Some((token, challenge))).await?;
        let mut session = connect_with_token(connection.transport, &endpoint, token)
            .await
            .map_err(ConnectError::into_report)?;
        result = list_session(&session).await;
        finish(&mut session).await;
    }
    let mut tools = result.map_err(|error| {
        if error.is::<ServiceError>() {
            anyhow::anyhow!("external MCP tools/list failed")
        } else {
            error
        }
    })?;
    tools.sort_by(|left, right| left.name.cmp(&right.name));
    let mut names = HashSet::new();
    for tool in &tools {
        ensure!(
            !tool.name.is_empty() && names.insert(&tool.name),
            "external MCP catalog has an empty or duplicate tool name"
        );
    }
    Ok(tools)
}

async fn list_session(session: &Session) -> Result<Vec<Tool>> {
    let mut tools = Vec::new();
    let mut cursor = None;
    let mut seen = HashSet::new();
    for _ in 0..MAX_PAGES {
        let page = session
            .list_tools(Some(PaginatedRequestParams::default().with_cursor(cursor)))
            .await?;
        ensure!(
            page.tools.len() <= MAX_TOOLS - tools.len(),
            "external MCP catalog has more than {MAX_TOOLS} tools"
        );
        tools.extend(page.tools);
        match &page.next_cursor {
            None => return Ok(tools),
            Some(next) if !seen.insert(next.clone()) => {
                anyhow::bail!("external MCP server repeated a tools/list cursor")
            }
            _ => cursor = page.next_cursor,
        }
    }
    anyhow::bail!("external MCP catalog has more than {MAX_PAGES} pages")
}

pub(super) async fn call(
    connection: &Connection,
    integration: Uuid,
    tool: String,
    args: JsonObject,
) -> Result<CallToolResult> {
    let (mut session, auth) = connect(connection, integration).await?;
    let response = session
        .call_tool(CallToolRequestParams::new(tool).with_arguments(args))
        .await;
    if let Err(error) = &response {
        recover_after_rejection(auth, error);
    }
    finish(&mut session).await;
    response.map_err(|error| {
        if service_challenge(&error).is_some() {
            anyhow::anyhow!("external MCP server rejected authorization during tools/call")
        } else {
            anyhow::anyhow!("external MCP tools/call failed")
        }
    })
}

async fn finish(session: &mut Session) {
    let _ = session.close_with_timeout(Duration::from_secs(1)).await;
}

type ActiveAuth = Option<(Auth, Option<String>)>;

async fn connect(connection: &Connection, integration: Uuid) -> Result<(Session, ActiveAuth)> {
    let endpoint = connection.validate()?;
    let auth = connection.oauth.clone().map(|settings| Auth {
        endpoint: endpoint.clone(),
        settings,
        integration,
        no_browser: connection.no_browser,
    });
    let token = if let Some(auth) = &auth {
        auth.clone().token(None).await?
    } else {
        connection.token_env.as_deref().map(secret).transpose()?
    };

    match connect_with_token(connection.transport, &endpoint, token.clone()).await {
        Ok(session) => Ok((session, auth.map(|auth| (auth, token)))),
        Err(ConnectError::Unauthorized(challenge)) => {
            let auth = auth.context("external MCP server requires valid credentials")?;
            let token = auth.clone().token(Some((token, challenge))).await?;
            let session = connect_with_token(connection.transport, &endpoint, token.clone())
                .await
                .map_err(|error| error.into_report())?;
            Ok((session, Some((auth, token))))
        }
        Err(error) => Err(error.into_report()),
    }
}

fn recover_after_rejection(auth: ActiveAuth, error: &ServiceError) {
    if let (Some((auth, token)), Some(challenge)) = (auth, service_challenge(error)) {
        // The operation may already have reached the server. Recover credentials
        // for the next call without automatically resending the original call.
        tokio::spawn(async move {
            if let Err(error) = auth.token(Some((token, challenge))).await {
                eprintln!("MCP OAuth recovery failed: {error}");
            }
        });
    }
}

fn service_challenge(error: &ServiceError) -> Option<Challenge> {
    match error {
        ServiceError::TransportSend(error) => transport_challenge(error),
        _ => None,
    }
}

fn transport_challenge(error: &DynamicTransportError) -> Option<Challenge> {
    match error
        .error
        .downcast_ref::<StreamableHttpError<reqwest::Error>>()
    {
        Some(StreamableHttpError::AuthRequired(error)) => {
            return Some(Challenge::from_header(&error.www_authenticate_header));
        }
        Some(StreamableHttpError::InsufficientScope(error)) => {
            return Some(Challenge::insufficient_scope(
                &error.www_authenticate_header,
            ));
        }
        Some(StreamableHttpError::UnexpectedServerResponse(message))
            if message.starts_with("HTTP 401 ") =>
        {
            return Some(Challenge::default());
        }
        _ => {}
    }
    match error.error.downcast_ref::<LegacyError>() {
        Some(LegacyError::Unauthorized(challenge)) => Some(challenge.clone()),
        _ => None,
    }
}

enum ConnectError {
    Unauthorized(Challenge),
    Failed(anyhow::Error),
}

impl ConnectError {
    fn into_report(self) -> anyhow::Error {
        match self {
            Self::Unauthorized(_) => anyhow::anyhow!("external MCP server rejected authorization"),
            Self::Failed(error) => error,
        }
    }
}

async fn connect_with_token(
    transport: TransportKind,
    endpoint: &Url,
    token: Option<String>,
) -> std::result::Result<Session, ConnectError> {
    let http = http_client().map_err(ConnectError::Failed)?;
    let mut info = ClientInfo::default();
    info.client_info = Implementation::new(env!("CARGO_PKG_NAME"), env!("CARGO_PKG_VERSION"));

    let result = match transport {
        TransportKind::Http => {
            let mut config = StreamableHttpClientTransportConfig::with_uri(endpoint.as_str())
                .reinit_on_expired_session(false);
            if let Some(token) = token {
                config = config.auth_header(token);
            }
            info.serve(StreamableHttpClientTransport::with_client(http, config))
                .await
        }
        TransportKind::Sse => {
            info.protocol_version = ProtocolVersion::V_2024_11_05;
            let transport = LegacySse::open(http, endpoint, token)
                .await
                .map_err(|error| match error {
                    LegacyError::Unauthorized(challenge) => ConnectError::Unauthorized(challenge),
                    error => ConnectError::Failed(error.into()),
                })?;
            info.serve(transport).await
        }
    };
    result.map_err(|error| {
        if let ClientInitializeError::TransportError { error, .. } = &error
            && let Some(challenge) = transport_challenge(error)
        {
            return ConnectError::Unauthorized(challenge);
        }
        ConnectError::Failed(anyhow::anyhow!(
            "external MCP session initialization failed"
        ))
    })
}

fn http_client() -> Result<Client> {
    static CLIENT: OnceLock<Client> = OnceLock::new();
    if let Some(client) = CLIENT.get() {
        return Ok(client.clone());
    }
    let client = Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .retry(reqwest::retry::never())
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 10 {
                attempt.error("too many MCP redirects")
            } else if attempt
                .previous()
                .first()
                .is_some_and(|origin| origin.origin() == attempt.url().origin())
                && attempt.url().username().is_empty()
                && attempt.url().password().is_none()
            {
                attempt.follow()
            } else {
                attempt.error("cross-origin MCP redirects are disabled")
            }
        }))
        .build()?;
    Ok(CLIENT.get_or_init(|| client).clone())
}

struct LegacySse {
    http: Client,
    post: Url,
    token: Option<String>,
    stream: BoxStream<'static, std::result::Result<Sse, sse_stream::Error>>,
}

#[derive(Debug, thiserror::Error)]
enum LegacyError {
    #[error("legacy MCP SSE authorization rejected")]
    Unauthorized(Challenge),
    #[error("legacy MCP SSE request failed")]
    Request,
    #[error("legacy MCP SSE server returned HTTP {0}")]
    Http(StatusCode),
    #[error("legacy MCP SSE server did not return an event stream")]
    ContentType,
    #[error("legacy MCP SSE server did not send a usable message endpoint")]
    InvalidEndpoint,
}

impl LegacySse {
    async fn open(
        http: Client,
        url: &Url,
        token: Option<String>,
    ) -> std::result::Result<Self, LegacyError> {
        let request = http
            .get(url.clone())
            .header(header::ACCEPT, "text/event-stream");
        let response = checked_response(with_token(request, token.as_deref()).send().await)?;
        if !response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| {
                value
                    .split(';')
                    .next()
                    .is_some_and(|value| value.trim().eq_ignore_ascii_case("text/event-stream"))
            })
        {
            return Err(LegacyError::ContentType);
        }
        let base = response.url().clone();
        let mut stream = SseStream::from_bytes_stream(response.bytes_stream()).boxed();
        while let Some(event) = stream.next().await {
            let event = event.map_err(|_| LegacyError::Request)?;
            if event.event.as_deref() != Some("endpoint") {
                continue;
            }
            let post = event
                .data
                .as_deref()
                .and_then(|path| base.join(path.trim()).ok())
                .filter(|target| {
                    target.origin() == url.origin()
                        && target.username().is_empty()
                        && target.password().is_none()
                        && target.fragment().is_none()
                })
                .ok_or(LegacyError::InvalidEndpoint)?;
            return Ok(Self {
                http,
                post,
                token,
                stream,
            });
        }
        Err(LegacyError::InvalidEndpoint)
    }
}

impl Transport<RoleClient> for LegacySse {
    type Error = LegacyError;

    fn send(
        &mut self,
        message: ClientJsonRpcMessage,
    ) -> impl Future<Output = std::result::Result<(), Self::Error>> + Send + 'static {
        let request =
            with_token(self.http.post(self.post.clone()), self.token.as_deref()).json(&message);
        async move {
            checked_response(request.send().await)?;
            Ok(())
        }
    }

    async fn receive(&mut self) -> Option<ServerJsonRpcMessage> {
        while let Some(Ok(event)) = self.stream.next().await {
            if matches!(event.event.as_deref(), None | Some("message"))
                && let Some(data) = event.data
            {
                return serde_json::from_str(&data).ok();
            }
        }
        None
    }

    async fn close(&mut self) -> std::result::Result<(), Self::Error> {
        self.stream = futures_util::stream::empty().boxed();
        Ok(())
    }
}

fn with_token(request: reqwest::RequestBuilder, token: Option<&str>) -> reqwest::RequestBuilder {
    match token {
        Some(token) => request.bearer_auth(token),
        None => request,
    }
}

fn checked_response(
    response: reqwest::Result<reqwest::Response>,
) -> std::result::Result<reqwest::Response, LegacyError> {
    let response = response.map_err(|_| LegacyError::Request)?;
    let status = response.status();
    if matches!(status, StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN) {
        let challenge = response
            .headers()
            .get(header::WWW_AUTHENTICATE)
            .and_then(|value| value.to_str().ok())
            .map(Challenge::from_header)
            .unwrap_or_default();
        if status == StatusCode::UNAUTHORIZED || challenge.scope_upgrade {
            return Err(LegacyError::Unauthorized(challenge));
        }
    }
    if !status.is_success() {
        return Err(LegacyError::Http(status));
    }
    Ok(response)
}
