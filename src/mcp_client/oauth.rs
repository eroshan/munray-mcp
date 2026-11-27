use super::{
    config::{OAuth, endpoint, secret},
    credential_store::{self, CredentialStore},
};
use anyhow::{Context, Result, bail, ensure};
use oauth2::{
    AsyncHttpClient, AuthType, AuthUrl, AuthorizationCode, ClientId, ClientSecret, CsrfToken,
    EndpointNotSet, EndpointSet, HttpRequest, HttpResponse, PkceCodeChallenge, PkceCodeVerifier,
    RedirectUrl, RefreshToken, RequestTokenError, Scope, TokenResponse, TokenUrl,
    basic::{BasicClient, BasicErrorResponseType, BasicTokenType},
};
use parking_lot::Mutex;
use reqwest::{Client, StatusCode, Url};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    env,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    pin::Pin,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    process::Command,
    time::timeout,
};
use uuid::Uuid;

const LOGIN_LIMIT: Duration = Duration::from_secs(300);
const MAX_AUTH_JSON: usize = 1024 * 1024;

#[derive(Clone)]
pub(super) struct Auth {
    pub endpoint: Url,
    pub settings: OAuth,
    pub integration: Uuid,
    pub no_browser: bool,
}

#[derive(Clone, Debug, Default)]
pub(super) struct Challenge {
    metadata: Option<String>,
    scope: Option<String>,
    pub scope_upgrade: bool,
}

impl Challenge {
    pub(super) fn from_header(header: &str) -> Self {
        let header = header.trim_start();
        let attributes = header
            .split_once(char::is_whitespace)
            .filter(|(scheme, _)| scheme.eq_ignore_ascii_case("Bearer"))
            .map_or("", |(_, rest)| rest);
        let parameter = |key: &str| {
            attributes.split(',').find_map(|part| {
                let (name, value) = part.trim().split_once('=')?;
                name.trim()
                    .eq_ignore_ascii_case(key)
                    .then(|| value.trim().trim_matches('"').to_owned())
            })
        };
        Self {
            metadata: parameter("resource_metadata"),
            scope: parameter("scope"),
            scope_upgrade: parameter("error").as_deref() == Some("insufficient_scope"),
        }
    }

    pub(super) fn insufficient_scope(header: &str) -> Self {
        Self {
            scope_upgrade: true,
            ..Self::from_header(header)
        }
    }

    fn scopes(&self) -> impl Iterator<Item = &str> {
        self.scope
            .as_deref()
            .filter(|_| self.scope_upgrade)
            .unwrap_or_default()
            .split_whitespace()
    }
}

#[derive(Deserialize)]
struct ResourceMetadata {
    resource: String,
    #[serde(default)]
    authorization_servers: Vec<String>,
    #[serde(default)]
    scopes_supported: Vec<String>,
}

#[derive(Clone, Serialize, Deserialize)]
struct Provider {
    issuer: String,
    authorization_endpoint: String,
    token_endpoint: String,
    registration_endpoint: Option<String>,
    #[serde(default)]
    scopes_supported: Vec<String>,
    code_challenge_methods_supported: Option<Vec<String>>,
    token_endpoint_auth_methods_supported: Option<Vec<String>>,
    #[serde(default)]
    authorization_response_iss_parameter_supported: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct Registration {
    client_id: String,
    client_secret: Option<String>,
    token_endpoint_auth_method: Option<String>,
}

enum TokenAuthentication {
    Public,
    Basic(String),
    Post(String),
}

type OAuthClient =
    BasicClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;

enum TokenGrant {
    AuthorizationCode(AuthorizationCode, PkceCodeVerifier),
    Refresh(RefreshToken),
}

#[derive(Serialize, Deserialize)]
struct Token {
    access_token: String,
    refresh_token: Option<String>,
    expiration: Option<u64>,
}

#[derive(Serialize, Deserialize)]
pub(super) struct Session {
    provider: Provider,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    resource: Option<String>,
    registration: Registration,
    redirect: String,
    scopes: Vec<String>,
    token: Option<Token>,
}

impl Session {
    fn resource<'a>(&'a self, endpoint: &'a Url) -> &'a str {
        self.resource
            .as_deref()
            .unwrap_or_else(|| endpoint.as_str())
    }
}

impl Auth {
    pub(super) async fn token(
        self,
        rejection: Option<(Option<String>, Challenge)>,
    ) -> Result<Option<String>> {
        // Complete a browser flow even if the originating Lua invocation times out.
        // The lock also coordinates refresh-token rotation with other CLI processes.
        tokio::spawn(async move {
            timeout(LOGIN_LIMIT, self.resolve(rejection))
                .await
                .context("OAuth login or refresh timed out")?
        })
        .await
        .context("OAuth task failed")?
    }

    async fn resolve(
        &self,
        rejection: Option<(Option<String>, Challenge)>,
    ) -> Result<Option<String>> {
        if let Some(name) = &self.settings.client_secret_env {
            secret(name)?;
        }
        let key_data = serde_json::to_vec(&(&self.endpoint.as_str(), &self.settings))?;
        let key = format!("{}-{:x}", self.integration, Sha256::digest(key_data));
        let store = credential_store::open(&key).await?;
        let mut session = store.load()?;
        let challenged = rejection.is_some();
        let (rejected, challenge) = rejection.unwrap_or_default();
        let requested = challenge.scopes().collect::<Vec<_>>();
        if let Some(configured) = &self.settings.scope {
            ensure!(
                requested
                    .iter()
                    .all(|scope| configured.split_whitespace().any(|known| known == *scope)),
                "external MCP server requires OAuth scopes outside the configured scope"
            );
        }
        let missing_scope = session.as_ref().is_some_and(|cached| {
            requested
                .iter()
                .any(|scope| !cached.scopes.iter().any(|known| known == *scope))
        });
        if let Some(token) = session.as_ref().and_then(|session| session.token.as_ref()) {
            let expired = token
                .expiration
                .is_some_and(|expiration| expiration <= now());
            if !expired
                && Some(token.access_token.as_str()) != rejected.as_deref()
                && !missing_scope
            {
                return Ok(Some(token.access_token.clone()));
            }
        } else if !challenged && session.is_none() {
            // Attempt an anonymous handshake to obtain the server's challenge.
            return Ok(None);
        }

        let http = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(20))
            .build()?;
        let mut replace_registration = missing_scope && self.settings.client_id.is_none();
        let cached_authentication = match session
            .as_ref()
            .map(|cached| self.token_authentication(&cached.provider, &cached.registration))
        {
            Some(Ok(authentication)) => Some(authentication),
            Some(Err(_)) if self.settings.client_id.is_none() => {
                replace_registration = true;
                None
            }
            Some(Err(error)) => return Err(error),
            None => None,
        };
        if !challenge.scope_upgrade
            && let Some(authentication) = cached_authentication
            && let Some(cached) = &mut session
            && let Some(refresh) = cached
                .token
                .as_ref()
                .and_then(|token| token.refresh_token.as_deref())
        {
            let client = self.oauth_client(cached, authentication)?;
            let result = exchange(
                &http,
                &client,
                cached.resource(&self.endpoint),
                TokenGrant::Refresh(RefreshToken::new(refresh.to_owned())),
            )
            .await?;
            match result {
                TokenReply::Granted(mut token) => {
                    if token.refresh_token.is_none() {
                        token.refresh_token = Some(refresh.to_owned());
                    }
                    return save_token(&store, cached, token).map(Some);
                }
                TokenReply::LoginRequired {
                    invalid_client: true,
                } if self.settings.client_id.is_none() => {
                    replace_registration = true;
                }
                TokenReply::LoginRequired { .. } => {}
            }
        }

        self.login(&http, &store, session, &challenge, replace_registration)
            .await
            .map(Some)
    }

    async fn login(
        &self,
        http: &Client,
        store: &dyn CredentialStore,
        mut cached: Option<Session>,
        challenge: &Challenge,
        mut replace_registration: bool,
    ) -> Result<String> {
        let has_saved_token = cached
            .as_ref()
            .is_some_and(|session| session.token.is_some());
        for _ in 0..2 {
            let preferred = cached.as_ref().map(|session| session.redirect.as_str());
            let (listener, redirect) = callback_listener(&self.settings, preferred).await?;
            let mut session = match cached.take() {
                Some(mut session) => {
                    for scope in challenge.scopes() {
                        if !session.scopes.iter().any(|known| known == scope) {
                            session.scopes.push(scope.to_owned());
                        }
                    }
                    if replace_registration || session.redirect != redirect.as_str() {
                        session.registration = self
                            .register_client(
                                http,
                                &session.provider,
                                redirect.as_str(),
                                &session.scopes,
                            )
                            .await?;
                        session.redirect = redirect.to_string();
                    }
                    session
                }
                _ => self.register(http, redirect.as_str(), challenge).await?,
            };
            let authentication =
                self.token_authentication(&session.provider, &session.registration)?;
            let client = self.oauth_client(&session, authentication)?;
            let resource = session.resource(&self.endpoint);
            let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
            let (authorization_url, state) = client
                .authorize_url(CsrfToken::new_random)
                .set_pkce_challenge(challenge)
                .add_scopes(session.scopes.iter().cloned().map(Scope::new))
                .add_extra_param("resource", resource)
                .url();
            // Retain prior credentials until authorization succeeds. An initial
            // login can still save its registration for reuse after cancellation.
            if !has_saved_token {
                store.save(&session)?;
            }
            eprintln!("Authorize the MCP integration in your browser:\n{authorization_url}");
            if !self.no_browser {
                tokio::spawn(open_browser(authorization_url));
            }
            let response =
                receive_callback(&listener, &redirect, state.secret(), &session.provider).await?;
            let result = match response {
                Callback::Code(code) => {
                    exchange(
                        http,
                        &client,
                        resource,
                        TokenGrant::AuthorizationCode(AuthorizationCode::new(code), verifier),
                    )
                    .await?
                }
                Callback::InvalidClient => TokenReply::LoginRequired {
                    invalid_client: true,
                },
            };
            match result {
                TokenReply::Granted(token) => return save_token(store, &mut session, token),
                TokenReply::LoginRequired {
                    invalid_client: true,
                } if self.settings.client_id.is_none() => {
                    // The provider discarded its dynamic registration. Re-register once.
                    cached = Some(session);
                    replace_registration = true;
                }
                TokenReply::LoginRequired { .. } => {
                    bail!("OAuth provider rejected the authorization code or client")
                }
            }
        }
        bail!("OAuth provider rejected the new dynamic client registration")
    }

    async fn register(
        &self,
        http: &Client,
        redirect: &str,
        challenge: &Challenge,
    ) -> Result<Session> {
        let (provider, resource, suggested) = self.discover(http, challenge).await?;
        ensure!(
            provider
                .code_challenge_methods_supported
                .as_ref()
                .is_none_or(|methods| methods.iter().any(|method| method == "S256")),
            "OAuth provider does not support PKCE S256"
        );
        let scope = self
            .settings
            .scope
            .as_deref()
            .or(challenge.scope.as_deref());
        let mut scopes = match scope {
            Some(scope) => scope
                .split_whitespace()
                .map(str::to_owned)
                .collect::<Vec<_>>(),
            None if !suggested.is_empty() => suggested,
            None => provider.scopes_supported.clone(),
        };
        if !scopes.iter().any(|scope| scope == "offline_access")
            && provider
                .scopes_supported
                .iter()
                .any(|scope| scope == "offline_access")
        {
            scopes.push("offline_access".to_owned());
        }
        let registration = self
            .register_client(http, &provider, redirect, &scopes)
            .await?;
        Ok(Session {
            provider,
            resource: Some(resource),
            registration,
            redirect: redirect.to_owned(),
            scopes,
            token: None,
        })
    }

    async fn register_client(
        &self,
        http: &Client,
        provider: &Provider,
        redirect: &str,
        scopes: &[String],
    ) -> Result<Registration> {
        let registration: Registration = if let Some(client_id) = &self.settings.client_id {
            Registration {
                client_id: client_id.clone(),
                client_secret: None,
                token_endpoint_auth_method: None,
            }
        } else {
            let url = provider
                .registration_endpoint
                .as_deref()
                .context("OAuth provider requires a pre-registered client ID")?;
            let response = http
                .post(self.provider_endpoint(url)?)
                .json(&serde_json::json!({
                    "client_name": env!("CARGO_PKG_NAME"),
                    "redirect_uris": [redirect],
                    "grant_types": ["authorization_code", "refresh_token"],
                    "response_types": ["code"],
                    "token_endpoint_auth_method": "none",
                    "scope": scopes.join(" "),
                }))
                .send()
                .await
                .map_err(|_| anyhow::anyhow!("OAuth registration request failed"))?;
            http_json(response, "OAuth client registration").await?
        };
        ensure!(
            !registration.client_id.is_empty(),
            "OAuth registration returned an empty client ID"
        );
        Ok(registration)
    }

    async fn discover(
        &self,
        http: &Client,
        challenge: &Challenge,
    ) -> Result<(Provider, String, Vec<String>)> {
        let mut resource_urls = well_known(&self.endpoint, "oauth-protected-resource", false);
        let root_url = resource_urls
            .pop()
            .context("missing root OAuth discovery URL")?;
        if let Some(url) = challenge.metadata.as_deref()
            && let Ok(url) = self.provider_endpoint(url)
        {
            resource_urls.insert(0, url);
        }
        let root_resource = self.endpoint.origin().ascii_serialization();
        let candidates = resource_urls
            .into_iter()
            .map(|url| (url, self.endpoint.as_str()))
            .chain([(root_url, root_resource.as_str())]);
        let mut resource_mismatch = false;
        for (url, expected_resource) in candidates {
            let Some(resource) = discover_json::<ResourceMetadata>(http, url).await? else {
                continue;
            };
            if resource.resource != expected_resource {
                resource_mismatch = true;
                continue;
            }
            for issuer in resource.authorization_servers {
                let issuer = self.provider_endpoint(&issuer)?;
                if let Some(provider) = self.discover_provider(http, &issuer, true).await? {
                    return Ok((provider, resource.resource, resource.scopes_supported));
                }
            }
        }
        if let Some(provider) = self.discover_provider(http, &self.endpoint, false).await? {
            return Ok((provider, self.endpoint.to_string(), Vec::new()));
        }
        if resource_mismatch {
            bail!(
                "OAuth resource metadata does not match the configured MCP endpoint or its root resource"
            );
        }
        bail!("MCP server did not advertise a usable OAuth provider")
    }

    async fn discover_provider(
        &self,
        http: &Client,
        issuer: &Url,
        verify_issuer: bool,
    ) -> Result<Option<Provider>> {
        let mut urls = well_known(issuer, "oauth-authorization-server", true);
        urls.extend(well_known(issuer, "openid-configuration", true));
        for url in urls {
            if let Some(provider) = discover_json::<Provider>(http, url).await? {
                let metadata_issuer = self.provider_endpoint(&provider.issuer)?;
                ensure!(
                    if verify_issuer {
                        &metadata_issuer == issuer
                    } else {
                        metadata_issuer.origin() == issuer.origin()
                    },
                    "OAuth metadata issuer does not match the discovered provider"
                );
                self.provider_endpoint(&provider.authorization_endpoint)?;
                self.provider_endpoint(&provider.token_endpoint)?;
                return Ok(Some(provider));
            }
        }
        Ok(None)
    }

    fn provider_endpoint(&self, url: &str) -> Result<Url> {
        let url = endpoint(url)?;
        ensure!(
            self.endpoint.scheme() != "https" || url.scheme() == "https",
            "OAuth discovery cannot downgrade HTTPS to loopback HTTP"
        );
        Ok(url)
    }

    fn token_authentication(
        &self,
        provider: &Provider,
        registration: &Registration,
    ) -> Result<TokenAuthentication> {
        let auth_method = registration.token_endpoint_auth_method.as_deref();
        if auth_method == Some("none") {
            return Ok(TokenAuthentication::Public);
        }
        let client_secret = match &self.settings.client_secret_env {
            Some(name) => Some(secret(name)?),
            None => registration
                .client_secret
                .as_ref()
                .filter(|secret| !secret.is_empty())
                .cloned(),
        };
        match (auth_method, client_secret) {
            (Some("client_secret_basic"), Some(secret)) => Ok(TokenAuthentication::Basic(secret)),
            (Some("client_secret_post"), Some(secret)) => Ok(TokenAuthentication::Post(secret)),
            (Some(method @ ("client_secret_basic" | "client_secret_post")), None) => {
                bail!(
                    "OAuth token authentication method {method} requires a non-empty client secret"
                )
            }
            (Some(method), _) => bail!("unsupported OAuth token authentication method {method}"),
            (None, None) => Ok(TokenAuthentication::Public),
            (None, Some(secret)) => match provider.token_endpoint_auth_methods_supported.as_deref()
            {
                None => Ok(TokenAuthentication::Basic(secret)),
                Some(methods) if methods.iter().any(|method| method == "client_secret_basic") => {
                    Ok(TokenAuthentication::Basic(secret))
                }
                Some(methods) if methods.iter().any(|method| method == "client_secret_post") => {
                    Ok(TokenAuthentication::Post(secret))
                }
                Some(_) => bail!(
                    "OAuth provider does not advertise a supported client-secret authentication method"
                ),
            },
        }
    }

    fn oauth_client(
        &self,
        session: &Session,
        authentication: TokenAuthentication,
    ) -> Result<OAuthClient> {
        let mut client = BasicClient::new(ClientId::new(session.registration.client_id.clone()))
            .set_auth_uri(AuthUrl::from_url(
                self.provider_endpoint(&session.provider.authorization_endpoint)?,
            ))
            .set_token_uri(TokenUrl::from_url(
                self.provider_endpoint(&session.provider.token_endpoint)?,
            ))
            .set_redirect_uri(
                RedirectUrl::new(session.redirect.clone()).context("invalid OAuth callback URL")?,
            );
        let (auth_type, client_secret) = match authentication {
            TokenAuthentication::Public => (AuthType::RequestBody, None),
            TokenAuthentication::Basic(secret) => (AuthType::BasicAuth, Some(secret)),
            TokenAuthentication::Post(secret) => (AuthType::RequestBody, Some(secret)),
        };
        if let Some(secret) = client_secret {
            client = client.set_client_secret(ClientSecret::new(secret));
        }
        Ok(client.set_auth_type(auth_type))
    }
}

async fn exchange(
    http: &Client,
    client: &OAuthClient,
    resource: &str,
    grant: TokenGrant,
) -> Result<TokenReply> {
    let transport = TokenHttp {
        client: http,
        status: Mutex::new(None),
    };
    let reply = match grant {
        TokenGrant::AuthorizationCode(code, verifier) => {
            client
                .exchange_code(code)
                .set_pkce_verifier(verifier)
                .add_extra_param("resource", resource)
                .request_async(&transport)
                .await
        }
        TokenGrant::Refresh(token) => {
            client
                .exchange_refresh_token(&token)
                .add_extra_param("resource", resource)
                .request_async(&transport)
                .await
        }
    };
    let reply = match reply {
        Ok(reply) => reply,
        Err(RequestTokenError::ServerResponse(error))
            if error.error() == &BasicErrorResponseType::InvalidGrant =>
        {
            return Ok(TokenReply::LoginRequired {
                invalid_client: false,
            });
        }
        Err(RequestTokenError::ServerResponse(error))
            if error.error() == &BasicErrorResponseType::InvalidClient =>
        {
            return Ok(TokenReply::LoginRequired {
                invalid_client: true,
            });
        }
        Err(RequestTokenError::Request(TokenHttpError::Transport(error))) => return Err(error),
        Err(_) => match *transport.status.lock() {
            Some(StatusCode::OK) => bail!("invalid OAuth token response (expected JSON)"),
            Some(status) => bail!("OAuth token request failed (HTTP {status})"),
            None => bail!("could not build OAuth token request"),
        },
    };
    let access_token = reply.access_token().secret();
    ensure!(
        reply.token_type() == &BasicTokenType::Bearer && !access_token.is_empty(),
        "OAuth token endpoint did not return a usable bearer token"
    );
    Ok(TokenReply::Granted(Token {
        access_token: access_token.clone(),
        refresh_token: reply.refresh_token().map(|token| token.secret().clone()),
        expiration: reply
            .expires_in()
            .map(|duration| now().saturating_add(duration.as_secs())),
    }))
}

struct TokenHttp<'a> {
    client: &'a Client,
    // Keep diagnostics independent of the provider's error text and response body.
    status: Mutex<Option<StatusCode>>,
}

impl<'a> AsyncHttpClient<'a> for TokenHttp<'_> {
    type Error = TokenHttpError;
    type Future = Pin<Box<dyn Future<Output = Result<HttpResponse, Self::Error>> + Send + 'a>>;

    fn call(&'a self, request: HttpRequest) -> Self::Future {
        Box::pin(async move {
            let mut request = request;
            if let Some(header) = request
                .headers_mut()
                .get_mut(reqwest::header::AUTHORIZATION)
            {
                header.set_sensitive(true);
            }
            let request = request
                .try_into()
                .map_err(|_| anyhow::anyhow!("invalid OAuth token request"))?;
            let response = self
                .client
                .execute(request)
                .await
                .map_err(|_| anyhow::anyhow!("OAuth token request failed"))?;
            let status = response.status();
            *self.status.lock() = Some(status);
            let headers = response.headers().clone();
            let body = read_response_body(response).await?;
            // oauth2 5.0 accepts trailing data and skips strings in unknown fields.
            serde_json::from_slice::<serde_json::Value>(&body)
                .map_err(|_| TokenHttpError::InvalidJson)?;
            let mut reply = HttpResponse::new(body);
            *reply.status_mut() = status;
            *reply.headers_mut() = headers;
            Ok(reply)
        })
    }
}

#[derive(Debug, thiserror::Error)]
enum TokenHttpError {
    #[error(transparent)]
    Transport(#[from] anyhow::Error),
    #[error("invalid OAuth token JSON response")]
    InvalidJson,
}

enum TokenReply {
    Granted(Token),
    LoginRequired { invalid_client: bool },
}

fn well_known(url: &Url, kind: &str, append_to_path: bool) -> Vec<Url> {
    let path = url.path().trim_matches('/');
    let root = format!("/.well-known/{kind}");
    let mut paths = Vec::new();
    if !path.is_empty() {
        paths.push(format!("{root}/{path}"));
        if append_to_path {
            paths.push(format!("/{path}{root}"));
        }
    }
    paths.push(root);
    paths
        .into_iter()
        .map(|path| {
            let mut target = url.clone();
            target.set_path(&path);
            target.set_query(None);
            target
        })
        .collect()
}

async fn discover_json<T: DeserializeOwned>(http: &Client, url: Url) -> Result<Option<T>> {
    let response = http
        .get(url)
        .header("MCP-Protocol-Version", "2025-11-25")
        .send()
        .await;
    match response {
        Ok(response) if response.status() == StatusCode::OK => Ok(read_json(response).await.ok()),
        _ => Ok(None),
    }
}

async fn http_json<T: DeserializeOwned>(response: reqwest::Response, operation: &str) -> Result<T> {
    let status = response.status();
    ensure!(status.is_success(), "{operation} failed (HTTP {status})");
    read_json(response).await
}

async fn read_json<T: DeserializeOwned>(response: reqwest::Response) -> Result<T> {
    let data = read_response_body(response).await?;
    serde_json::from_slice(&data).map_err(|_| anyhow::anyhow!("invalid OAuth JSON response"))
}

async fn read_response_body(mut response: reqwest::Response) -> Result<Vec<u8>> {
    let mut data = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| anyhow::anyhow!("read OAuth response failed"))?
    {
        ensure!(
            chunk.len() <= MAX_AUTH_JSON - data.len(),
            "OAuth response exceeds 1 MiB"
        );
        data.extend_from_slice(&chunk);
    }
    Ok(data)
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn save_token(store: &dyn CredentialStore, session: &mut Session, token: Token) -> Result<String> {
    let access = token.access_token.clone();
    session.token = Some(token);
    store.save(session)?;
    Ok(access)
}

async fn callback_listener(
    settings: &OAuth,
    preferred: Option<&str>,
) -> Result<(TcpListener, Url)> {
    let mut url = settings.callback()?;
    let ip = if url.host_str() == Some("[::1]") {
        IpAddr::V6(Ipv6Addr::LOCALHOST)
    } else {
        IpAddr::V4(Ipv4Addr::LOCALHOST)
    };
    let fixed_port = url.port().unwrap_or_else(|| {
        if settings.callback_url.as_deref().is_some_and(|input| {
            input
                .split("://")
                .nth(1)
                .and_then(|host| host.split('/').next())
                .is_some_and(|host| host.ends_with(":80"))
        }) {
            80
        } else {
            0
        }
    });
    let cached_port = preferred
        .and_then(|url| Url::parse(url).ok())
        .and_then(|url| url.port());
    let port = if fixed_port == 0 {
        cached_port.unwrap_or(0)
    } else {
        fixed_port
    };

    let listener = match TcpListener::bind((ip, port)).await {
        Err(_) if fixed_port == 0 && port != 0 => TcpListener::bind((ip, 0)).await,
        result => result,
    }
    .context("bind OAuth loopback callback")?;
    url.set_port(Some(listener.local_addr()?.port()))
        .map_err(|_| anyhow::anyhow!("invalid OAuth callback port"))?;
    Ok((listener, url))
}

enum Callback {
    Code(String),
    InvalidClient,
}

async fn receive_callback(
    listener: &TcpListener,
    redirect: &Url,
    state: &str,
    provider: &Provider,
) -> Result<Callback> {
    loop {
        let (mut stream, _) = listener.accept().await?;
        if let Ok(Ok(Some(response))) = timeout(
            Duration::from_secs(5),
            handle_callback(&mut stream, redirect, state, provider),
        )
        .await
        {
            return response;
        }
    }
}

async fn handle_callback(
    stream: &mut TcpStream,
    redirect: &Url,
    state: &str,
    provider: &Provider,
) -> Result<Option<Result<Callback>>> {
    let mut bytes = Vec::new();
    let mut chunk = [0; 1024];
    let end = loop {
        let count = stream.read(&mut chunk).await?;
        if count == 0 || bytes.len() + count > 8192 {
            return Ok(None);
        }
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            break end;
        }
    };
    let headers = std::str::from_utf8(&bytes[..end])?;
    let mut lines = headers.split("\r\n");
    let mut request = lines.next().unwrap_or_default().split_ascii_whitespace();
    let method = request.next();
    let path = request.next().unwrap_or_default();
    let host = lines.find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.eq_ignore_ascii_case("host").then(|| value.trim())
    });
    let mut expected_host = redirect.host_str().unwrap_or_default().to_owned();
    if let Some(port) = redirect.port() {
        expected_host.push_str(&format!(":{port}"));
    }
    let response = if method == Some("GET")
        && host.is_some_and(|host| host.eq_ignore_ascii_case(&expected_host))
        && path.starts_with('/')
        && !path.starts_with("//")
    {
        let target = redirect.join(path)?;
        (target.path() == redirect.path())
            .then(|| verify_callback(&target, state, provider))
            .flatten()
    } else {
        None
    };

    let (status, message) = if response.is_some() {
        (
            "200 OK",
            "Authorization response received. You can close this tab.",
        )
    } else {
        ("400 Bad Request", "Invalid OAuth callback.")
    };
    let reply = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: {}\r\n\r\n{message}",
        message.len()
    );
    let _ = stream.write_all(reply.as_bytes()).await;
    Ok(response)
}

fn verify_callback(target: &Url, state: &str, provider: &Provider) -> Option<Result<Callback>> {
    let query = target.query_pairs().collect::<Vec<_>>();
    let field = |key: &str| {
        let mut matches = query.iter().filter(|(name, _)| name == key);
        let value = matches.next()?.1.as_ref();
        matches.next().is_none().then_some(value)
    };
    if !bool::from(field("state")?.as_bytes().ct_eq(state.as_bytes())) {
        return None;
    }
    let issuer = field("iss");
    if (provider.authorization_response_iss_parameter_supported || issuer.is_some())
        && issuer != Some(provider.issuer.as_str())
    {
        return Some(Err(anyhow::anyhow!(
            "OAuth callback issuer does not match provider"
        )));
    }
    if let Some(error) = field("error") {
        if error == "invalid_client" {
            return Some(Ok(Callback::InvalidClient));
        }
        return Some(Err(anyhow::anyhow!("OAuth provider denied authorization")));
    }
    field("code")
        .filter(|code| !code.is_empty())
        .map(|code| Ok(Callback::Code(code.to_owned())))
}

async fn open_browser(url: Url) {
    let mut command = if cfg!(target_os = "macos") {
        Command::new("open")
    } else if cfg!(windows) {
        let mut command = Command::new("rundll32");
        command.arg("url.dll,FileProtocolHandler");
        command
    } else {
        Command::new("xdg-open")
    };
    let result = timeout(
        Duration::from_secs(5),
        command
            .arg(url.as_str())
            .kill_on_drop(true)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status(),
    )
    .await;
    if !matches!(result, Ok(Ok(status)) if status.success()) {
        eprintln!("Could not open the browser automatically. Use the OAuth link above.");
    }
}
