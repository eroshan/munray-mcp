use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc::{SyncSender, TrySendError, sync_channel},
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use mlua::{Lua, LuaSerdeExt, Table, Value};
use parking_lot::Mutex;
use serde_json::{Value as JsonValue, json};

use crate::runtime::lua_error;

const MAX_RUNNING: usize = 10;
const WORKERS: usize = 4;
const QUEUE_CAPACITY: usize = MAX_RUNNING;
const RESULT_LIMIT: usize = 10 * 1024 * 1024;
const RETENTION: Duration = Duration::from_secs(5 * 60);

type Job = Box<dyn FnOnce() + Send + 'static>;

#[derive(Clone)]
pub(crate) struct Manager {
    tasks: Arc<Mutex<HashMap<String, Task>>>,
    jobs: SyncSender<Job>,
}

struct Task {
    state: TaskState,
    started_at_ms: u128,
    finished_at_ms: Option<u128>,
    cancellation: Arc<AtomicBool>,
}

enum TaskState {
    Running,
    Completed(JsonValue),
    Failed(TaskFailure),
    Cancelled,
}

pub(crate) struct TaskFailure {
    code: String,
    message: String,
    recoverable: bool,
}

impl TaskFailure {
    pub(crate) fn new(
        code: impl Into<String>,
        message: impl Into<String>,
        recoverable: bool,
    ) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            recoverable,
        }
    }
}

impl Manager {
    pub(crate) fn new() -> Self {
        let tasks = Arc::new(Mutex::new(HashMap::<String, Task>::new()));
        let (jobs, receiver) = sync_channel::<Job>(QUEUE_CAPACITY);
        let receiver = Arc::new(Mutex::new(receiver));
        for _ in 0..WORKERS {
            let receiver = Arc::clone(&receiver);
            thread::spawn(move || {
                loop {
                    let job = match receiver.lock().recv() {
                        Ok(job) => job,
                        Err(_) => break,
                    };
                    job();
                }
            });
        }
        Self { tasks, jobs }
    }

    pub(crate) fn start<F>(&self, function: F) -> Result<String, String>
    where
        F: FnOnce(Arc<AtomicBool>) -> Result<JsonValue, TaskFailure> + Send + 'static,
    {
        let id = uuid::Uuid::new_v4().to_string();
        let cancellation = Arc::new(AtomicBool::new(false));
        {
            let mut tasks = self.tasks.lock();
            prune_completed(&mut tasks);
            if tasks
                .values()
                .filter(|task| matches!(task.state, TaskState::Running))
                .count()
                >= MAX_RUNNING
            {
                return Err("too many concurrent tasks".into());
            }
            tasks.insert(
                id.clone(),
                Task {
                    state: TaskState::Running,
                    started_at_ms: now_ms(),
                    finished_at_ms: None,
                    cancellation: Arc::clone(&cancellation),
                },
            );
        }
        let tasks = Arc::clone(&self.tasks);
        let task_id = id.clone();
        let job: Job = Box::new(move || {
            let result = function(Arc::clone(&cancellation));
            let mut tasks = tasks.lock();
            let Some(task) = tasks.get_mut(&task_id) else {
                return;
            };
            if matches!(task.state, TaskState::Cancelled) {
                return;
            }
            task.finished_at_ms = Some(now_ms());
            task.state = match result {
                Ok(value) => match serde_json::to_vec(&value) {
                    Ok(encoded) if encoded.len() <= RESULT_LIMIT => TaskState::Completed(value),
                    Ok(_) => TaskState::Failed(TaskFailure::new(
                        "RESULT_TOO_LARGE",
                        "task result exceeded 10485760 bytes",
                        false,
                    )),
                    Err(error) => TaskState::Failed(TaskFailure::new(
                        "RESULT_SERIALIZATION_FAILED",
                        error.to_string(),
                        false,
                    )),
                },
                Err(error) => TaskState::Failed(error),
            };
        });
        match self.jobs.try_send(job) {
            Ok(()) => Ok(id),
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                self.tasks.lock().remove(&id);
                Err("task executor is busy".into())
            }
        }
    }

    pub(crate) fn cancel_all(&self) {
        let mut tasks = self.tasks.lock();
        for task in tasks.values_mut() {
            if matches!(task.state, TaskState::Running) {
                task.cancellation.store(true, Ordering::Release);
                task.state = TaskState::Cancelled;
                task.finished_at_ms = Some(now_ms());
            }
        }
    }
}

pub(crate) fn register(
    lua: &Lua,
    raw: &Table,
    allowed_cli: Arc<Mutex<Vec<String>>>,
    manager: Manager,
) -> mlua::Result<()> {
    let cli: Table = raw.get("cli")?;
    for (name, parse_json) in [("start_text", false), ("start_json", true)] {
        let manager = manager.clone();
        let allowed = Arc::clone(&allowed_cli);
        cli.set(
            name,
            lua.create_function(
                move |lua, (tool, args, opts): (String, Table, Option<Table>)| {
                    if !allowed.lock().iter().any(|candidate| candidate == &tool) {
                        return lua_error(
                            lua,
                            "CLI_NOT_ALLOWED",
                            format!("CLI command '{tool}' is not allowed"),
                            false,
                        );
                    }
                    let args = args
                        .sequence_values::<Value>()
                        .map(|value| value.and_then(|value| value.to_string()))
                        .collect::<mlua::Result<Vec<_>>>()?;
                    let timeout = opts
                        .as_ref()
                        .and_then(|opts| opts.get::<f64>("timeout").ok())
                        .filter(|timeout| timeout.is_finite() && *timeout > 0.0)
                        .unwrap_or(60.0);
                    let cwd = opts.and_then(|opts| opts.get::<String>("cwd").ok());
                    match manager.start(move |cancellation| {
                        run_command(
                            &tool,
                            &args,
                            cwd.as_deref(),
                            timeout,
                            parse_json,
                            &cancellation,
                        )
                    }) {
                        Ok(id) => Ok((Value::String(lua.create_string(&id)?), Value::Nil)),
                        Err(error) => lua_error(lua, "TOO_MANY_TASKS", error, true),
                    }
                },
            )?,
        )?;
    }

    let task: Table = raw.get("task")?;
    let status_manager = manager.clone();
    task.set("status", lua.create_function(move |lua, id: String| {
        let mut tasks = status_manager.tasks.lock();
        prune_completed(&mut tasks);
        let Some(task) = tasks.get(&id) else { return lua_error(lua, "NOT_FOUND", "unknown task".into(), false) };
        Ok((lua.to_value(&json!({"state":state_name(&task.state),"started_at_ms":task.started_at_ms,"finished_at_ms":task.finished_at_ms}))?, Value::Nil))
    })?)?;

    let result_manager = manager.clone();
    task.set(
        "result",
        lua.create_function(move |lua, id: String| task_result(lua, &result_manager, &id))?,
    )?;

    let wait_manager = manager.clone();
    task.set(
        "wait",
        lua.create_function(move |lua, (id, timeout_ms): (String, Option<u64>)| {
            let requested = Duration::from_millis(timeout_ms.unwrap_or(295_000));
            let Some(timeout) = crate::deadline::effective(requested) else {
                return lua_error(
                    lua,
                    "TIMEOUT",
                    "execution deadline exceeded while waiting for task".into(),
                    true,
                );
            };
            let started = std::time::Instant::now();
            loop {
                if started.elapsed() >= timeout || crate::deadline::expired() {
                    return lua_error(lua, "TIMEOUT", "timed out waiting for task".into(), true);
                }
                let running = wait_manager
                    .tasks
                    .lock()
                    .get(&id)
                    .is_some_and(|task| matches!(task.state, TaskState::Running));
                if !running {
                    return task_result(lua, &wait_manager, &id);
                }
                thread::sleep(Duration::from_millis(20));
            }
        })?,
    )?;

    let cancel_manager = manager.clone();
    task.set(
        "cancel",
        lua.create_function(move |lua, id: String| {
            let mut tasks = cancel_manager.tasks.lock();
            let Some(task) = tasks.get_mut(&id) else {
                return lua_error(lua, "NOT_FOUND", "unknown task".into(), false);
            };
            if matches!(task.state, TaskState::Running) {
                task.cancellation.store(true, Ordering::Release);
                task.state = TaskState::Cancelled;
                task.finished_at_ms = Some(now_ms());
                Ok((Value::Boolean(true), Value::Nil))
            } else {
                Ok((Value::Boolean(false), Value::Nil))
            }
        })?,
    )?;

    let test: Table = raw.get("test")?;
    let test_manager = manager;
    test.set(
        "start_task",
        lua.create_function(move |lua, (delay_ms, result): (u64, Value)| {
            let result: JsonValue = lua.from_value(result)?;
            match test_manager.start(move |cancellation| {
                let started = std::time::Instant::now();
                while started.elapsed() < Duration::from_millis(delay_ms) {
                    if cancellation.load(Ordering::Acquire) {
                        return Err(TaskFailure::new("CANCELLED", "task cancelled", false));
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Ok(result)
            }) {
                Ok(id) => Ok((Value::String(lua.create_string(&id)?), Value::Nil)),
                Err(error) => lua_error(lua, "TOO_MANY_TASKS", error, true),
            }
        })?,
    )?;
    Ok(())
}

fn task_result(lua: &Lua, manager: &Manager, id: &str) -> mlua::Result<(Value, Value)> {
    let mut tasks = manager.tasks.lock();
    prune_completed(&mut tasks);
    let Some(task) = tasks.get(id) else {
        return lua_error(lua, "NOT_FOUND", "unknown task".into(), false);
    };
    match &task.state {
        TaskState::Running => lua_error(lua, "NOT_READY", "task still running".into(), true),
        TaskState::Completed(value) => Ok((lua.to_value(value)?, Value::Nil)),
        TaskState::Failed(error) => {
            lua_error(lua, &error.code, error.message.clone(), error.recoverable)
        }
        TaskState::Cancelled => lua_error(lua, "CANCELLED", "task cancelled".into(), false),
    }
}

fn run_command(
    tool: &str,
    args: &[String],
    cwd: Option<&str>,
    timeout_seconds: f64,
    parse_json: bool,
    cancellation: &AtomicBool,
) -> Result<JsonValue, TaskFailure> {
    let mut command = std::process::Command::new(tool);
    command.args(args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let requested = Duration::from_secs_f64(timeout_seconds);
    let Some(timeout) = crate::deadline::effective(requested) else {
        return Err(TaskFailure::new(
            "TIMEOUT",
            "execution deadline exceeded",
            true,
        ));
    };
    let output = crate::process::capture_cancellable(
        &mut command,
        timeout,
        200 * 1024 * 1024,
        Some(cancellation),
    )
    .map_err(|error| TaskFailure::new("CLI_ERROR", error.to_string(), true))?;
    if output.timed_out {
        return Err(TaskFailure::new(
            "TIMEOUT",
            format!("CLI command timed out after {timeout_seconds}s"),
            true,
        ));
    }
    if output.cancelled {
        return Err(TaskFailure::new("CANCELLED", "task cancelled", false));
    }
    if output.stdout_exceeded {
        return Err(TaskFailure::new(
            "RESULT_TOO_LARGE",
            "CLI output exceeded 209715200 bytes",
            false,
        ));
    }
    if !output.status.success() {
        return Err(TaskFailure::new(
            "CLI_ERROR",
            String::from_utf8_lossy(&output.stderr).to_string(),
            false,
        ));
    }
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    if parse_json {
        serde_json::from_str(&stdout)
            .map_err(|error| TaskFailure::new("CLI_ERROR", error.to_string(), true))
    } else {
        Ok(JsonValue::String(stdout))
    }
}

fn prune_completed(tasks: &mut HashMap<String, Task>) {
    let now = now_ms();
    let retention_ms = RETENTION.as_millis();
    tasks.retain(|_, task| {
        matches!(task.state, TaskState::Running)
            || task
                .finished_at_ms
                .is_some_and(|finished| now.saturating_sub(finished) <= retention_ms)
    });
}

fn state_name(state: &TaskState) -> &'static str {
    match state {
        TaskState::Running => "running",
        TaskState::Completed(_) => "completed",
        TaskState::Failed(_) => "failed",
        TaskState::Cancelled => "cancelled",
    }
}
fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
