use std::{
    collections::{BTreeSet, HashMap},
    path::PathBuf,
    sync::{
        Arc, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};

use parking_lot::{Condvar, Mutex};
use rmcp::{
    ServerHandler,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{
        CreateElicitationRequestParams, ElicitationAction, ElicitationSchema, EnumSchema,
        Implementation, NumberOrString, ServerCapabilities, ServerInfo,
    },
    service::{ElicitationMode, RequestContext, RoleServer},
    tool, tool_handler, tool_router,
};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::runtime::{ExecutionMode, LuaRuntime};

static NEXT_ARRIVAL: AtomicU64 = AtomicU64::new(1 << 62);
static PENDING_ARRIVALS: OnceLock<Mutex<HashMap<String, BTreeSet<u64>>>> = OnceLock::new();

#[derive(Debug, Deserialize, JsonSchema)]
pub struct ScriptRequest {
    /// Lua code to execute.
    code: String,
    /// Optional session identifier for persistent global state.
    session_id: Option<String>,
    /// Optional execution timeout in milliseconds (clamped to 100ms–10min).
    timeout_ms: Option<u64>,
    #[serde(skip)]
    #[schemars(skip)]
    arrival: u64,
}

fn remove_pending_arrival(session_id: &str, arrival: u64) {
    let mut pending = PENDING_ARRIVALS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock();
    if let Some(arrivals) = pending.get_mut(session_id) {
        arrivals.remove(&arrival);
        if arrivals.is_empty() {
            pending.remove(session_id);
        }
    }
}

fn mutating_confirmation_message(request: &ScriptRequest) -> String {
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
    format!("Mutating Lua execution requested.\n\nSession: {session}\nCode preview:\n{preview}")
}

fn mutating_confirmation_schema() -> Result<ElicitationSchema, String> {
    let choices = vec!["Approve".to_owned(), "Reject".to_owned()];
    let decision = EnumSchema::builder(choices.clone())
        .title("Approve mutating operation?")
        .description("Select Approve to execute the mutating code, or Reject to cancel")
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
    sessions: Arc<Mutex<HashMap<String, Arc<Session>>>>,
    service_dir: Option<PathBuf>,
    store_path: Option<PathBuf>,
    session_ttl: Duration,
    logger: Option<crate::logging::Logger>,
}

struct Session {
    runtime: Mutex<LuaRuntime>,
    next_ticket: AtomicU64,
    serving: Mutex<u64>,
    ready: Condvar,
    last_used: Mutex<Instant>,
    request_active: Mutex<bool>,
}

impl Session {
    fn new(runtime: LuaRuntime) -> Self {
        Self {
            runtime: Mutex::new(runtime),
            next_ticket: AtomicU64::new(0),
            serving: Mutex::new(0),
            ready: Condvar::new(),
            last_used: Mutex::new(Instant::now()),
            request_active: Mutex::new(false),
        }
    }

    fn ordered<T>(&self, function: impl FnOnce(&LuaRuntime) -> T) -> T {
        *self.last_used.lock() = Instant::now();
        let ticket = self.next_ticket.fetch_add(1, Ordering::Relaxed);
        let mut serving = self.serving.lock();
        while *serving != ticket {
            self.ready.wait(&mut serving);
        }
        drop(serving);
        let result = function(&self.runtime.lock());
        let mut serving = self.serving.lock();
        *serving += 1;
        self.ready.notify_all();
        result
    }

    fn ordered_request<T>(
        &self,
        session_id: &str,
        arrival: u64,
        function: impl FnOnce(&LuaRuntime) -> T,
    ) -> T {
        *self.last_used.lock() = Instant::now();
        std::thread::sleep(Duration::from_millis(5));
        let mut active = self.request_active.lock();
        loop {
            let is_next = PENDING_ARRIVALS
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .get(session_id)
                .and_then(BTreeSet::first)
                .is_some_and(|next| *next == arrival);
            if !*active && is_next {
                *active = true;
                let mut pending = PENDING_ARRIVALS
                    .get_or_init(|| Mutex::new(HashMap::new()))
                    .lock();
                if let Some(arrivals) = pending.get_mut(session_id) {
                    arrivals.remove(&arrival);
                    if arrivals.is_empty() {
                        pending.remove(session_id);
                    }
                }
                break;
            }
            self.ready.wait_for(&mut active, Duration::from_millis(1));
        }
        drop(active);
        let result = function(&self.runtime.lock());
        *self.request_active.lock() = false;
        self.ready.notify_all();
        result
    }
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
    pub fn new(service_dir: Option<PathBuf>) -> Self {
        Self::with_store_path(service_dir, None)
    }

    pub fn with_store_path(service_dir: Option<PathBuf>, store_path: Option<PathBuf>) -> Self {
        Self::with_options(service_dir, store_path, None)
    }

    pub fn with_options(
        service_dir: Option<PathBuf>,
        store_path: Option<PathBuf>,
        logs_dir: Option<PathBuf>,
    ) -> Self {
        Self {
            tool_router: Self::tool_router(),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            service_dir,
            store_path,
            session_ttl: Duration::from_secs(30 * 60),
            logger: logs_dir
                .as_deref()
                .and_then(|path| crate::logging::Logger::new(path).ok()),
        }
    }

    #[tool(
        name = "lua_runLuaScript",
        description = "Execute Lua scripts in read-only mode. See initialize instructions for discovery, session reuse, and scoping guidance."
    )]
    async fn run_lua(
        &self,
        Parameters(mut request): Parameters<ScriptRequest>,
        context: RequestContext<RoleServer>,
    ) -> Result<String, String> {
        self.admit_request(&mut request, &context.id);
        self.execute(request, ExecutionMode::ReadOnly)
    }

    #[tool(
        name = "lua_runMutatingLuaScript",
        description = "Execute Lua scripts with explicit mutation permission."
    )]
    async fn run_mutating_lua(
        &self,
        Parameters(mut request): Parameters<ScriptRequest>,
        context: RequestContext<RoleServer>,
    ) -> Result<String, String> {
        self.admit_request(&mut request, &context.id);
        if context
            .peer
            .supported_elicitation_modes()
            .contains(&ElicitationMode::Form)
        {
            let message = mutating_confirmation_message(&request);
            let schema = mutating_confirmation_schema()?;
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
                    return self.reject_mutating(request, status);
                }
                Err(_) => return self.reject_mutating(request, "elicitation_failed"),
            }
        }
        self.execute(request, ExecutionMode::Mutating)
    }

    fn reject_mutating(&self, request: ScriptRequest, status: &str) -> Result<String, String> {
        if let Some(session_id) = &request.session_id {
            remove_pending_arrival(session_id, request.arrival);
        }
        let session_id = request
            .session_id
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        serde_json::to_string_pretty(&json!({
            "session_id": session_id,
            "output": "",
            "result": Value::Null,
            "error": {
                "code": "MUTATING_REJECTED",
                "message": format!("mutating operation {status} by user"),
                "recoverable": false
            },
            "confirmation": {
                "status": status,
                "mode": "mutating"
            }
        }))
        .map_err(|error| error.to_string())
    }

    fn admit_request(&self, request: &mut ScriptRequest, request_id: &NumberOrString) {
        request.arrival = match request_id {
            NumberOrString::Number(value) if *value >= 0 => *value as u64,
            _ => NEXT_ARRIVAL.fetch_add(1, Ordering::Relaxed),
        };
        if let Some(session_id) = &request.session_id {
            PENDING_ARRIVALS
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .entry(session_id.clone())
                .or_default()
                .insert(request.arrival);
        }
    }

    fn execute(&self, request: ScriptRequest, mode: ExecutionMode) -> Result<String, String> {
        if request.code.is_empty() {
            if let Some(session_id) = &request.session_id {
                remove_pending_arrival(session_id, request.arrival);
            }
            return Err("'code' parameter is required and must be a non-empty string".into());
        }
        let explicit_session = request.session_id.clone();
        let session_id = explicit_session
            .clone()
            .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        // Admission is global, but execution is queued per session. Reused
        // sessions remain strict FIFO while independent sessions run concurrently.
        let session = {
            let mut sessions = self.sessions.lock();
            Self::retain_live_sessions(&mut sessions, Instant::now(), self.session_ttl);
            if let Some(session) = sessions.get(&session_id) {
                Arc::clone(session)
            } else {
                let runtime =
                    LuaRuntime::new_mcp(self.service_dir.as_deref(), self.store_path.as_deref())
                        .map_err(|error| error.to_string())?;
                runtime
                    .set_server_id(&std::process::id().to_string())
                    .map_err(|error| error.to_string())?;
                let session = Arc::new(Session::new(runtime));
                sessions.insert(session_id.clone(), Arc::clone(&session));
                session
            }
        };
        let timeout = std::time::Duration::from_millis(
            request.timeout_ms.unwrap_or(60_000).clamp(100, 600_000),
        );
        let started = Instant::now();
        let run = |runtime: &LuaRuntime| {
            let execution =
                runtime.execute_with_timeout(&request.code, mode, "<mcp>", Some(timeout));
            (execution, runtime.captured_output())
        };
        let (execution, captured_output) = match explicit_session {
            Some(_) => session.ordered_request(&session_id, request.arrival, run),
            None => session.ordered(run),
        };
        let (output, result, error) = match execution {
            Ok(value) => (value.output, value.result, None),
            Err(error) => (captured_output, Value::Null, Some(format!("{error:#}"))),
        };
        if let Some(logger) = &self.logger {
            let _ = logger.log(crate::logging::ExecutionEntry {
                timestamp_ms: crate::logging::now_ms(),
                session_id: session_id.clone(),
                mode: match mode {
                    ExecutionMode::ReadOnly => "readonly",
                    ExecutionMode::Mutating => "mutating",
                }
                .into(),
                code: request.code.clone(),
                output: output.clone(),
                result: result.clone(),
                error: error.clone(),
                duration_ms: started.elapsed().as_millis(),
            });
        }
        let payload =
            json!({"session_id":session_id,"output":output,"result":result,"error":error});
        serde_json::to_string_pretty(&payload).map_err(|error| error.to_string())
    }

    fn retain_live_sessions(
        sessions: &mut HashMap<String, Arc<Session>>,
        now: Instant,
        ttl: Duration,
    ) {
        sessions.retain(|_, session| {
            Arc::strong_count(session) > 1
                || now.saturating_duration_since(*session.last_used.lock()) <= ttl
        });
    }

    pub(crate) fn ingest_existing(&self, session_id: &str, text: &str) -> Result<String, String> {
        let session = self
            .sessions
            .lock()
            .get(session_id)
            .cloned()
            .ok_or_else(|| "unknown or expired session".to_owned())?;
        session.ordered(|runtime| runtime.ingest_text(text).map_err(|error| error.to_string()))
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
            .with_instructions("Execute Lua with lua_runLuaScript by default. Reuse session_id to preserve global state; local variables are call-scoped. Use capabilities.ai_context() to discover APIs.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_idle_sessions_are_evicted_but_live_references_are_retained() {
        let stale = Arc::new(Session::new(LuaRuntime::new(None).unwrap()));
        *stale.last_used.lock() = Instant::now() - Duration::from_secs(60);
        let live = Arc::new(Session::new(LuaRuntime::new(None).unwrap()));
        *live.last_used.lock() = Instant::now() - Duration::from_secs(60);
        let _in_flight_reference = Arc::clone(&live);
        let mut sessions = HashMap::from([("stale".to_owned(), stale), ("live".to_owned(), live)]);

        McpServer::retain_live_sessions(&mut sessions, Instant::now(), Duration::from_secs(30));

        assert!(!sessions.contains_key("stale"));
        assert!(sessions.contains_key("live"));
    }
}
