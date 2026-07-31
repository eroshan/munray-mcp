use std::{collections::HashMap, process::Command, sync::Arc, time::Duration};

use mlua::{AnyUserData, Lua, Table, UserData, UserDataMethods, Value};
use parking_lot::Mutex;

use crate::runtime::lua_error;

const DEFAULT_MAX_BYTES: usize = 200 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct BlobStore {
    values: Arc<Mutex<HashMap<String, Arc<Vec<u8>>>>>,
}

impl BlobStore {
    pub(crate) fn new() -> Self {
        Self {
            values: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    fn put(&self, bytes: Vec<u8>) -> BlobRef {
        let id = uuid::Uuid::new_v4().to_string();
        let size = bytes.len();
        self.values.lock().insert(id.clone(), Arc::new(bytes));
        BlobRef { id, size }
    }

    pub(crate) fn get(&self, reference: &BlobRef) -> Option<Arc<Vec<u8>>> {
        self.values.lock().get(&reference.id).cloned()
    }
}

#[derive(Clone)]
pub(crate) struct BlobRef {
    id: String,
    size: usize,
}

impl UserData for BlobRef {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_meta_method(mlua::MetaMethod::ToString, |_, this, ()| {
            Ok(format!("blob({} bytes)", this.size))
        });
    }
}

pub(crate) fn register(
    lua: &Lua,
    raw: &Table,
    store: BlobStore,
    allowed_cli: Arc<Mutex<Vec<String>>>,
) -> mlua::Result<()> {
    let blob: Table = raw.get("blob")?;
    let capture_store = store.clone();
    blob.set(
        "from_cli",
        lua.create_function(
            move |lua, (tool, args, opts): (String, Table, Option<Table>)| {
                if !allowed_cli
                    .lock()
                    .iter()
                    .any(|candidate| candidate == &tool)
                {
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
                let max_bytes = opts
                    .as_ref()
                    .and_then(|opts| opts.get::<usize>("max_bytes").ok())
                    .unwrap_or(DEFAULT_MAX_BYTES);
                let timeout = opts
                    .as_ref()
                    .and_then(|opts| opts.get::<f64>("timeout").ok())
                    .filter(|timeout| timeout.is_finite() && *timeout > 0.0)
                    .unwrap_or(60.0);
                let Some(timeout) = crate::deadline::effective(Duration::from_secs_f64(timeout))
                else {
                    return lua_error(lua, "TIMEOUT", "execution deadline exceeded".into(), true);
                };
                let cwd = opts.and_then(|opts| opts.get::<String>("cwd").ok());
                let mut command = Command::new(&tool);
                command.args(args);
                if let Some(cwd) = cwd {
                    command.current_dir(cwd);
                }
                let output = match crate::process::capture(&mut command, timeout, max_bytes) {
                    Ok(output) => output,
                    Err(error) => return lua_error(lua, "CLI_ERROR", error.to_string(), true),
                };
                if output.timed_out {
                    return lua_error(
                        lua,
                        "TIMEOUT",
                        format!("CLI command timed out after {}ms", timeout.as_millis()),
                        true,
                    );
                }
                if !output.status.success() {
                    return lua_error(
                        lua,
                        "CLI_ERROR",
                        String::from_utf8_lossy(&output.stderr).to_string(),
                        false,
                    );
                }
                if output.stdout_exceeded {
                    return lua_error(
                        lua,
                        "RESULT_TOO_LARGE",
                        format!("blob exceeds max_bytes={max_bytes}"),
                        false,
                    );
                }
                let reference = capture_store.put(output.stdout);
                Ok((Value::UserData(lua.create_userdata(reference)?), Value::Nil))
            },
        )?,
    )?;

    let capture_store = store.clone();
    blob.set(
        "from_http",
        lua.create_function(
            move |lua, (method, base_url, path, opts): (String, String, String, Option<Table>)| {
                let opts = crate::http::options(lua, opts)?;
                let max_bytes = opts
                    .get("max_bytes")
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|value| usize::try_from(value).ok())
                    .filter(|value| *value > 0)
                    .unwrap_or(DEFAULT_MAX_BYTES);
                match crate::http::request_bytes(&method, &base_url, &path, &opts, max_bytes) {
                    Ok(bytes) => {
                        let reference = capture_store.put(bytes);
                        Ok((Value::UserData(lua.create_userdata(reference)?), Value::Nil))
                    }
                    Err(error) => lua_error(lua, &error.code, error.message, error.recoverable),
                }
            },
        )?,
    )?;

    blob.set(
        "len",
        lua.create_function(
            |lua, reference: AnyUserData| match reference.borrow::<BlobRef>() {
                Ok(reference) => Ok((Value::Integer(reference.size as i64), Value::Nil)),
                Err(_) => lua_error(
                    lua,
                    "VALIDATION_FAILED",
                    "blob argument is required".into(),
                    false,
                ),
            },
        )?,
    )?;
    Ok(())
}
