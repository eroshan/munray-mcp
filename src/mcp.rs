use std::{
    collections::{BTreeSet, HashMap},
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};

use parking_lot::{Condvar, Mutex};
use rmcp::{
    ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{
        CreateElicitationRequestParams, ElicitationAction, ElicitationSchema, EnumSchema,
        Implementation, ServerCapabilities, ServerInfo,
    },
    service::{ElicitationMode, RequestContext, RoleServer},
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::runtime::{ExecutionMode, LuaRuntime};

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ScriptRequest {
    /// Lua code to execute.
    code: String,
    /// Optional session identifier for persistent global state.
    session_id: Option<String>,
    /// Optional execution timeout in milliseconds (clamped to 100ms–10min).
    timeout_ms: Option<u64>,
}

fn guarded_confirmation_message(request: &ScriptRequest) -> String {
    let session = request
        .session_id
        .as_deref()
        .map(|id| id.chars().take(8).collect::<String>())
        .unwrap_or_else(|| "(new session)".to_owned());
    let trimmed = request.code.trim();
    let mut preview = trimmed.chars().take(240).collect::<String>();
    if trimmed.chars().count() > 240 {
        preview.push_str("... (truncated)");
    }
    format!("Guarded Lua execution requested.\n\nSession: {session}\nCode preview:\n{preview}")
}

fn guarded_confirmation_schema() -> Result<ElicitationSchema, String> {
    let choices = vec!["Approve".to_owned(), "Reject".to_owned()];
    let decision = EnumSchema::builder(choices.clone())
        .title("Approve guarded operation?")
        .description("Select Approve to execute the guarded code, or Reject to cancel")
        .enum_titles(choices)
        .map_err(|error| error.to_string())?
        .build();
    ElicitationSchema::builder()
        .required_enum_schema("decision", decision)
        .build()
        .map_err(str::to_owned)
}

#[derive(Clone)]
pub struct McpServer {
    tool_router: ToolRouter<Self>,
    sessions: Arc<Mutex<HashMap<String, SessionEntry>>>,
    service_dir: Option<PathBuf>,
    store_path: Option<PathBuf>,
    session_ttl: Duration,
    logger: Option<crate::logging::Logger>,
    instructions: String,
}

enum SessionEntry {
    Building(Arc<BuildState>),
    Ready(Arc<Session>),
}

struct BuildState {
    result: Mutex<Option<Result<Arc<Session>, String>>>,
    ready: Condvar,
    queue: Arc<SessionQueue>,
    started: AtomicBool,
}

struct SessionQueue {
    state: Mutex<QueueState>,
    ready: Condvar,
}

struct Session {
    runtime: Mutex<LuaRuntime>,
    queue: Arc<SessionQueue>,
    last_used: Mutex<Instant>,
}

struct QueueState {
    next_sequence: u64,
    serving: u64,
    cancelled: BTreeSet<u64>,
}

/// Reservation is made when the handler receives a request. Dropping it before
/// it runs advances/skips its place, so validation, elicitation, cancellation,
/// and runtime failures can never leave a dead queue head behind.
struct SessionPermit {
    queue: Arc<SessionQueue>,
    sequence: u64,
}

impl Session {
    fn with_queue(runtime: LuaRuntime, queue: Arc<SessionQueue>) -> Self {
        Self {
            runtime: Mutex::new(runtime),
            queue,
            last_used: Mutex::new(Instant::now()),
        }
    }

    fn reserve(&self) -> SessionPermit {
        *self.last_used.lock() = Instant::now();
        self.queue.reserve()
    }

    fn cancel_tasks(&self) {
        self.runtime.lock().cancel_tasks();
    }
}

impl SessionQueue {
    fn new() -> Self {
        Self {
            state: Mutex::new(QueueState {
                next_sequence: 0,
                serving: 0,
                cancelled: BTreeSet::new(),
            }),
            ready: Condvar::new(),
        }
    }
    fn reserve(self: &Arc<Self>) -> SessionPermit {
        let sequence = {
            let mut state = self.state.lock();
            let sequence = state.next_sequence;
            state.next_sequence += 1;
            sequence
        };
        SessionPermit {
            queue: Arc::clone(self),
            sequence,
        }
    }
}

impl SessionPermit {
    fn wait_turn(&self) {
        let mut queue = self.queue.state.lock();
        while queue.serving != self.sequence {
            self.queue.ready.wait(&mut queue);
        }
    }
}

impl Drop for SessionPermit {
    fn drop(&mut self) {
        let mut queue = self.queue.state.lock();
        if self.sequence < queue.serving {
            return;
        }
        if self.sequence == queue.serving {
            queue.serving += 1;
            loop {
                let serving = queue.serving;
                if !queue.cancelled.remove(&serving) {
                    break;
                }
                queue.serving += 1;
            }
        } else {
            queue.cancelled.insert(self.sequence);
        }
        self.queue.ready.notify_all();
    }
}

struct QueuedRequest {
    request: ScriptRequest,
    session_id: String,
    session: Arc<Session>,
    permit: SessionPermit,
}

const MCP_INSTRUCTIONS: &str = include_str!("assets/mcp-instructions.md");

fn initialization_instructions(service_dir: Option<&std::path::Path>) -> Result<String, String> {
    // Build the same trusted bootstrap used by sessions so only successfully
    // loaded packs can contribute introductions.
    let runtime = LuaRuntime::new(service_dir).map_err(|error| error.to_string())?;

    let mut introductions = Vec::new();
    for pack in &runtime.loaded_services().packs {
        if let Some(intro) = runtime
            .global_field_json(&pack.name, "__intro")
            .map_err(|error| format!("failed to read {}.__intro: {error:#}", pack.name))?
        {
            let intro = intro
                .as_str()
                .ok_or_else(|| format!("{}.__intro must be a string", pack.name))?;
            if !intro.trim().is_empty() {
                introductions.push(intro.trim().to_owned());
            }
        }
    }

    let mut instructions = MCP_INSTRUCTIONS.replace("{{server_name}}", env!("CARGO_PKG_NAME"));
    if !introductions.is_empty() {
        instructions.push_str("\n\n## Available service integrations\n\n");
        instructions.push_str(&introductions.join("\n\n"));
    }
    Ok(instructions)
}

impl std::fmt::Debug for McpServer {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("McpServer")
            .field("service_dir", &self.service_dir)
            .field("store_path", &self.store_path)
            .finish()
    }
}

#[tool_router]
impl McpServer {
    pub fn new(service_dir: Option<PathBuf>) -> Result<Self, String> {
        Self::with_store_path(service_dir, None)
    }
    pub fn with_store_path(
        service_dir: Option<PathBuf>,
        store_path: Option<PathBuf>,
    ) -> Result<Self, String> {
        Self::with_options(service_dir, store_path, None)
    }
    pub fn with_options(
        service_dir: Option<PathBuf>,
        store_path: Option<PathBuf>,
        logs_dir: Option<PathBuf>,
    ) -> Result<Self, String> {
        let instructions = initialization_instructions(service_dir.as_deref())?;
        Ok(Self {
            tool_router: Self::tool_router(),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            service_dir,
            store_path,
            session_ttl: Duration::from_secs(30 * 60),
            logger: logs_dir
                .as_deref()
                .and_then(|path| crate::logging::Logger::new(path).ok()),
            instructions,
        })
    }

    #[tool(
        name = "runLuaScript",
        description = "Execute Lua scripts in read-only mode. See initialize instructions for discovery, session reuse, and scoping guidance."
    )]
    async fn run_lua(
        &self,
        Parameters(request): Parameters<ScriptRequest>,
        _context: RequestContext<RoleServer>,
    ) -> Result<String, String> {
        let queued = self.prepare_request(request).await?;
        self.execute(queued, ExecutionMode::ReadOnly).await
    }

    #[tool(
        name = "runGuardedLuaScript",
        description = "Execute Lua scripts with explicit mutation permission."
    )]
    async fn run_guarded_lua(
        &self,
        Parameters(request): Parameters<ScriptRequest>,
        context: RequestContext<RoleServer>,
    ) -> Result<String, String> {
        let queued = self.prepare_request(request).await?;
        if context
            .peer
            .supported_elicitation_modes()
            .contains(&ElicitationMode::Form)
        {
            let message = guarded_confirmation_message(&queued.request);
            let schema = guarded_confirmation_schema()?;
            let params = CreateElicitationRequestParams::FormElicitationParams {
                meta: None,
                message,
                requested_schema: schema,
            };
            match context.peer.create_elicitation(params).await {
                Ok(response)
                    if response.action == ElicitationAction::Accept
                        && response.content.as_ref().and_then(|content| {
                            content.get("decision").and_then(Value::as_str)
                        }) == Some("Approve") => {}
                Ok(response) => {
                    let status = match response.action {
                        ElicitationAction::Accept => "rejected",
                        ElicitationAction::Decline => "declined",
                        ElicitationAction::Cancel => "cancelled",
                    };
                    return self.reject_guarded(queued.session_id, status);
                }
                Err(_) => return self.reject_guarded(queued.session_id, "elicitation_failed"),
            }
        }
        self.execute(queued, ExecutionMode::Guarded).await
    }

    fn reject_guarded(&self, session_id: String, status: &str) -> Result<String, String> {
        serde_json::to_string_pretty(&json!({"session_id":session_id,"output":"","result":Value::Null,"error":{"code":"REJECTED_BY_GUARD","message":format!("guarded operation {status} by user"),"recoverable":false},"confirmation":{"status":status,"mode":"guarded"}})).map_err(|error| error.to_string())
    }

    async fn prepare_request(&self, request: ScriptRequest) -> Result<QueuedRequest, String> {
        if request.code.is_empty() {
            return Err("'code' parameter is required and must be a non-empty string".into());
        }
        let session_id = request
            .session_id
            .clone()
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        // Allocate the queue ticket synchronously at handler receipt, before a
        // slow VM build can reorder concurrent same-session calls.
        let permit = self.reserve_queue(&session_id);
        let server = self.clone();
        let session_id_for_build = session_id.clone();
        // Constructing a Lua VM loads packs and SQLite. It never runs on the
        // Tokio executor and never holds the session-map mutex while doing so.
        let session = tokio::task::spawn_blocking(move || {
            server.get_or_create_session(&session_id_for_build)
        })
        .await
        .map_err(|error| error.to_string())??;
        Ok(QueuedRequest {
            request,
            session_id,
            session,
            permit,
        })
    }

    async fn execute(&self, queued: QueuedRequest, mode: ExecutionMode) -> Result<String, String> {
        let logger = self.logger.clone();
        tokio::task::spawn_blocking(move || {
            let QueuedRequest {
                request,
                session_id,
                session,
                permit,
            } = queued;
            let timeout =
                Duration::from_millis(request.timeout_ms.unwrap_or(60_000).clamp(100, 600_000));
            let started = Instant::now();
            permit.wait_turn();
            let (execution, captured_output) = {
                let runtime = session.runtime.lock();
                let execution =
                    runtime.execute_with_timeout(&request.code, mode, "<mcp>", Some(timeout));
                (execution, runtime.captured_output())
            };
            let (output, result, error) = match execution {
                Ok(value) => (value.output, value.result, None),
                Err(error) => (captured_output, Value::Null, Some(format!("{error:#}"))),
            };
            if let Some(logger) = logger {
                let _ = logger.log(crate::logging::ExecutionEntry {
                    timestamp_ms: crate::logging::now_ms(),
                    session_id: session_id.clone(),
                    mode: match mode {
                        ExecutionMode::ReadOnly => "readonly",
                        ExecutionMode::Guarded => "guarded",
                    }
                    .into(),
                    code: request.code,
                    output: output.clone(),
                    result: result.clone(),
                    error: error.clone(),
                    duration_ms: started.elapsed().as_millis(),
                });
            }
            serde_json::to_string_pretty(
                &json!({"session_id":session_id,"output":output,"result":result,"error":error}),
            )
            .map_err(|error| error.to_string())
        })
        .await
        .map_err(|error| error.to_string())?
    }

    fn reserve_queue(&self, session_id: &str) -> SessionPermit {
        let mut sessions = self.sessions.lock();
        Self::retain_live_sessions(&mut sessions, Instant::now(), self.session_ttl);
        match sessions.get(session_id) {
            Some(SessionEntry::Ready(session)) => session.reserve(),
            Some(SessionEntry::Building(state)) => state.queue.reserve(),
            None => {
                let queue = Arc::new(SessionQueue::new());
                let state = Arc::new(BuildState {
                    result: Mutex::new(None),
                    ready: Condvar::new(),
                    queue: Arc::clone(&queue),
                    started: AtomicBool::new(false),
                });
                sessions.insert(session_id.to_owned(), SessionEntry::Building(state));
                queue.reserve()
            }
        }
    }

    fn get_or_create_session(&self, session_id: &str) -> Result<Arc<Session>, String> {
        let (state, builder) = {
            let mut sessions = self.sessions.lock();
            Self::retain_live_sessions(&mut sessions, Instant::now(), self.session_ttl);
            match sessions.get(session_id) {
                Some(SessionEntry::Ready(session)) => return Ok(Arc::clone(session)),
                Some(SessionEntry::Building(state)) => {
                    let builder = !state.started.swap(true, Ordering::AcqRel);
                    (Arc::clone(state), builder)
                }
                None => {
                    let state = Arc::new(BuildState {
                        result: Mutex::new(None),
                        ready: Condvar::new(),
                        queue: Arc::new(SessionQueue::new()),
                        started: AtomicBool::new(true),
                    });
                    sessions.insert(
                        session_id.to_owned(),
                        SessionEntry::Building(Arc::clone(&state)),
                    );
                    (state, true)
                }
            }
        };
        if !builder {
            let mut result = state.result.lock();
            while result.is_none() {
                state.ready.wait(&mut result);
            }
            return result.as_ref().expect("build result present").clone();
        }
        let built = (|| {
            let runtime =
                LuaRuntime::new_mcp(self.service_dir.as_deref(), self.store_path.as_deref())
                    .map_err(|error| error.to_string())?;
            runtime
                .set_server_id(&std::process::id().to_string())
                .map_err(|error| error.to_string())?;
            Ok(Arc::new(Session::with_queue(
                runtime,
                Arc::clone(&state.queue),
            )))
        })();
        {
            let mut result = state.result.lock();
            *result = Some(built.clone());
            state.ready.notify_all();
        }
        let mut sessions = self.sessions.lock();
        match &built {
            Ok(session) => {
                sessions.insert(
                    session_id.to_owned(),
                    SessionEntry::Ready(Arc::clone(session)),
                );
            }
            Err(_) => {
                sessions.remove(session_id);
            }
        }
        built
    }

    fn retain_live_sessions(
        sessions: &mut HashMap<String, SessionEntry>,
        now: Instant,
        ttl: Duration,
    ) {
        let mut evicted = Vec::new();
        sessions.retain(|_, entry| match entry {
            SessionEntry::Building(_) => true,
            SessionEntry::Ready(session) => {
                let retain = Arc::strong_count(session) > 1
                    || now.saturating_duration_since(*session.last_used.lock()) <= ttl;
                if !retain {
                    evicted.push(Arc::clone(session));
                }
                retain
            }
        });
        for session in evicted {
            session.cancel_tasks();
        }
    }

    pub(crate) fn ingest_existing(&self, session_id: &str, text: &str) -> Result<String, String> {
        let session = match self.sessions.lock().get(session_id) {
            Some(SessionEntry::Ready(session)) => Arc::clone(session),
            _ => return Err("unknown or expired session".into()),
        };
        let permit = session.reserve();
        permit.wait_turn();
        session
            .runtime
            .lock()
            .ingest_text(text)
            .map_err(|error| error.to_string())
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for McpServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new(
                env!("CARGO_PKG_NAME"),
                env!("CARGO_PKG_VERSION"),
            ))
            .with_instructions(self.instructions.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancelled_reservation_does_not_block_the_session_queue() {
        let session = Arc::new(Session::with_queue(
            LuaRuntime::new(None).unwrap(),
            Arc::new(SessionQueue::new()),
        ));
        let first = session.reserve();
        let second = session.reserve();
        drop(first);
        second.wait_turn();
        assert_eq!(session.runtime.lock().captured_output(), "");
    }
}
