use std::{
    collections::HashMap,
    process::{Command, Stdio},
    sync::{Arc, OnceLock, Weak},
    thread,
    time::{Duration, Instant},
};

use mlua::{Lua, Table, Value};
use parking_lot::Mutex;
use serde_json::Value as JsonValue;

use crate::runtime::lua_error;

static COMMANDS: OnceLock<Mutex<HashMap<String, Arc<CommandSecret>>>> = OnceLock::new();

struct CommandSecret {
    tool: String,
    args: Vec<String>,
    timeout: Duration,
    ttl: Duration,
    allowed_cli: Weak<Mutex<Vec<String>>>,
    cache: Mutex<Option<(Instant, String)>>,
}

#[derive(Debug)]
pub(crate) struct SecretError {
    pub(crate) code: String,
    pub(crate) message: String,
    pub(crate) recoverable: bool,
}

pub(crate) fn register(
    lua: &Lua,
    raw: &Table,
    allowed_cli: Arc<Mutex<Vec<String>>>,
) -> mlua::Result<()> {
    let secrets: Table = raw.get("secrets")?;
    secrets.set(
        "env",
        lua.create_function(|lua, name: String| {
            if name.trim().is_empty() {
                return lua_error(
                    lua,
                    "VALIDATION_FAILED",
                    "environment variable name is required".into(),
                    false,
                );
            }
            let reference = lua.create_table()?;
            reference.set("kind", "env")?;
            reference.set("name", name)?;
            Ok((Value::Table(reference), Value::Nil))
        })?,
    )?;

    secrets.set(
        "command",
        lua.create_function(move |lua, spec: Table| {
            let tool = spec.get::<Option<String>>("tool")?.unwrap_or_default();
            if tool.trim().is_empty() {
                return lua_error(
                    lua,
                    "VALIDATION_FAILED",
                    "secret command tool cannot be empty".into(),
                    false,
                );
            }
            let timeout = spec.get::<Option<u64>>("timeout")?.unwrap_or(10);
            if timeout > 30 {
                return lua_error(
                    lua,
                    "VALIDATION_FAILED",
                    "secret command timeout exceeds 30 seconds".into(),
                    false,
                );
            }
            let ttl = spec.get::<Option<u64>>("ttl_s")?.unwrap_or(3600);
            let args = match spec.get::<Option<Table>>("args")? {
                Some(args) => args
                    .sequence_values::<Value>()
                    .map(|value| value.and_then(|value| value.to_string()))
                    .collect::<mlua::Result<Vec<_>>>()?,
                None => Vec::new(),
            };
            let id = uuid::Uuid::new_v4().to_string();
            COMMANDS
                .get_or_init(|| Mutex::new(HashMap::new()))
                .lock()
                .insert(
                    id.clone(),
                    Arc::new(CommandSecret {
                        tool,
                        args,
                        timeout: Duration::from_secs(timeout.max(1)),
                        ttl: Duration::from_secs(ttl),
                        allowed_cli: Arc::downgrade(&allowed_cli),
                        cache: Mutex::new(None),
                    }),
                );
            let reference = lua.create_table()?;
            reference.set("kind", "command")?;
            reference.set("id", id)?;
            Ok((Value::Table(reference), Value::Nil))
        })?,
    )?;
    Ok(())
}

pub(crate) fn resolve(value: &JsonValue) -> Result<String, SecretError> {
    if let Some(value) = value.as_str() {
        return Ok(value.to_owned());
    }
    match value.get("kind").and_then(JsonValue::as_str) {
        Some("env") => {
            let name = value
                .get("name")
                .and_then(JsonValue::as_str)
                .unwrap_or_default();
            std::env::var(name).map_err(|_| {
                failure(
                    "SECRET_NOT_FOUND",
                    format!("environment variable {name} is not configured"),
                    false,
                )
            })
        }
        Some("command") => resolve_command(
            value
                .get("id")
                .and_then(JsonValue::as_str)
                .unwrap_or_default(),
        ),
        _ => Err(failure(
            "VALIDATION_FAILED",
            "invalid secret reference",
            false,
        )),
    }
}

pub(crate) fn invalidate_command_bearer(auth: &JsonValue) -> bool {
    if auth.get("kind").and_then(JsonValue::as_str) != Some("bearer") {
        return false;
    }
    let token = &auth["token"];
    if token.get("kind").and_then(JsonValue::as_str) != Some("command") {
        return false;
    }
    let Some(id) = token.get("id").and_then(JsonValue::as_str) else {
        return false;
    };
    let Some(command) = COMMANDS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .get(id)
        .cloned()
    else {
        return false;
    };
    *command.cache.lock() = None;
    true
}

fn resolve_command(id: &str) -> Result<String, SecretError> {
    let command = COMMANDS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .get(id)
        .cloned()
        .ok_or_else(|| failure("SECRET_NOT_FOUND", "unknown command secret", false))?;
    let allowed = command
        .allowed_cli
        .upgrade()
        .ok_or_else(|| failure("SECRET_NOT_FOUND", "command secret session expired", false))?;
    if !allowed.lock().iter().any(|tool| tool == &command.tool) {
        return Err(failure(
            "CLI_NOT_ALLOWED",
            format!("CLI command '{}' is not allowed", command.tool),
            false,
        ));
    }
    if let Some((created, value)) = &*command.cache.lock()
        && created.elapsed() < command.ttl
    {
        return Ok(value.clone());
    }
    let value = execute(&command.tool, &command.args, command.timeout)?;
    *command.cache.lock() = Some((Instant::now(), value.clone()));
    Ok(value)
}

fn execute(tool: &str, args: &[String], timeout: Duration) -> Result<String, SecretError> {
    let timeout = crate::deadline::effective(timeout)
        .ok_or_else(|| failure("TIMEOUT", "execution deadline exceeded", true))?;
    let mut child = Command::new(tool)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| failure("SECRET_COMMAND_FAILED", error.to_string(), true))?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if started.elapsed() < timeout => thread::sleep(Duration::from_millis(10)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(failure(
                    "TIMEOUT",
                    format!("secret command timed out after {}s", timeout.as_secs()),
                    true,
                ));
            }
            Err(error) => {
                return Err(failure("SECRET_COMMAND_FAILED", error.to_string(), true));
            }
        }
    }
    let output = child
        .wait_with_output()
        .map_err(|error| failure("SECRET_COMMAND_FAILED", error.to_string(), true))?;
    if !output.status.success() {
        return Err(failure(
            "SECRET_COMMAND_FAILED",
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            false,
        ));
    }
    let value = String::from_utf8(output.stdout)
        .map_err(|_| failure("SECRET_COMMAND_FAILED", "secret is not valid UTF-8", false))?
        .trim()
        .to_owned();
    if value.is_empty() {
        return Err(failure(
            "SECRET_COMMAND_FAILED",
            "secret command returned empty output",
            false,
        ));
    }
    Ok(value)
}

fn failure(code: &str, message: impl Into<String>, recoverable: bool) -> SecretError {
    SecretError {
        code: code.into(),
        message: message.into(),
        recoverable,
    }
}

#[cfg(test)]
mod tests {
    use mlua::LuaSerdeExt;

    use super::*;

    #[test]
    fn command_secret_is_allowlisted_and_resolved() {
        let lua = Lua::new();
        let raw = lua.create_table().unwrap();
        raw.set("secrets", lua.create_table().unwrap()).unwrap();
        let allowed = Arc::new(Mutex::new(vec!["sh".to_owned()]));
        register(&lua, &raw, allowed).unwrap();
        lua.globals().set("sys", raw).unwrap();
        let reference: Value = lua
            .load(
                r#"local value, err = sys.secrets.command({tool="sh",args={"-c","printf secret-value"},timeout=2,ttl_s=10}); assert(not err); return value"#,
            )
            .eval()
            .unwrap();
        let reference: JsonValue = lua.from_value(reference).unwrap();
        assert_eq!(resolve(&reference).unwrap(), "secret-value");
        let id = reference["id"].as_str().unwrap().to_owned();
        let auth = serde_json::json!({"kind":"bearer","token":reference});
        assert!(invalidate_command_bearer(&auth));
        let command = COMMANDS.get().unwrap().lock().get(&id).cloned().unwrap();
        assert!(command.cache.lock().is_none());
    }

    #[test]
    fn command_secret_rejects_unlisted_tools() {
        let lua = Lua::new();
        let raw = lua.create_table().unwrap();
        raw.set("secrets", lua.create_table().unwrap()).unwrap();
        let allowed = Arc::new(Mutex::new(Vec::new()));
        register(&lua, &raw, allowed).unwrap();
        lua.globals().set("sys", raw).unwrap();
        let reference: Value = lua
            .load(r#"return sys.secrets.command({tool="sh"})"#)
            .eval()
            .unwrap();
        let reference: JsonValue = lua.from_value(reference).unwrap();
        assert_eq!(resolve(&reference).unwrap_err().code, "CLI_NOT_ALLOWED");
    }
}
