use std::{collections::HashMap, process::Command, sync::Arc, time::Duration};

use mlua::{AnyUserData, Lua, Table, UserData, UserDataMethods, Value};
use parking_lot::Mutex;

use crate::runtime::lua_error;

const DEFAULT_MAX_BYTES: usize = 200 * 1024 * 1024;
/// Runtime-wide cap prevents many individually valid captures exhausting memory.
const MAX_TOTAL_BYTES: usize = 512 * 1024 * 1024;

struct BlobState {
    values: HashMap<String, Arc<Vec<u8>>>,
    reserved: usize,
}

#[derive(Clone)]
pub(crate) struct BlobStore {
    state: Arc<Mutex<BlobState>>,
}

/// A capture reserves its maximum buffered size before reading bytes. This
/// makes the aggregate quota a memory bound, not an after-the-fact check.
struct BlobReservation {
    store: BlobStore,
    limit: usize,
    quota_limited: bool,
    committed: bool,
}

impl BlobStore {
    pub(crate) fn new() -> Self {
        Self {
            state: Arc::new(Mutex::new(BlobState {
                values: HashMap::new(),
                reserved: 0,
            })),
        }
    }

    fn reserve(&self, requested: usize) -> Result<BlobReservation, String> {
        let mut state = self.state.lock();
        let used = state
            .values
            .values()
            .map(|value| value.len())
            .sum::<usize>();
        let available = MAX_TOTAL_BYTES.saturating_sub(used.saturating_add(state.reserved));
        let limit = requested.min(available);
        if limit == 0 {
            return Err(format!("runtime blob quota is {MAX_TOTAL_BYTES} bytes"));
        }
        state.reserved += limit;
        Ok(BlobReservation {
            store: self.clone(),
            limit,
            quota_limited: requested > available,
            committed: false,
        })
    }

    pub(crate) fn get(&self, reference: &BlobRef) -> Option<Arc<Vec<u8>>> {
        self.state.lock().values.get(&reference.id).cloned()
    }
}

impl BlobReservation {
    fn limit(&self) -> usize {
        self.limit
    }

    fn quota_limited(&self) -> bool {
        self.quota_limited
    }

    fn commit(mut self, bytes: Vec<u8>) -> Result<BlobRef, String> {
        if bytes.len() > self.limit {
            return Err("captured blob exceeded its reserved quota".into());
        }
        let mut state = self.store.state.lock();
        state.reserved = state.reserved.saturating_sub(self.limit);
        let id = uuid::Uuid::new_v4().to_string();
        let size = bytes.len();
        state.values.insert(id.clone(), Arc::new(bytes));
        self.committed = true;
        Ok(BlobRef { id, size })
    }
}

impl Drop for BlobReservation {
    fn drop(&mut self) {
        if !self.committed {
            let mut state = self.store.state.lock();
            state.reserved = state.reserved.saturating_sub(self.limit);
        }
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
                let reservation = match capture_store.reserve(max_bytes) {
                    Ok(reservation) => reservation,
                    Err(error) => return lua_error(lua, "BLOB_QUOTA_EXCEEDED", error, false),
                };
                let cwd = opts.and_then(|opts| opts.get::<String>("cwd").ok());
                let mut command = Command::new(&tool);
                command.args(args);
                if let Some(cwd) = cwd {
                    command.current_dir(cwd);
                }
                let output =
                    match crate::process::capture(&mut command, timeout, reservation.limit()) {
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
                    let (code, message) = if reservation.quota_limited() {
                        (
                            "BLOB_QUOTA_EXCEEDED",
                            "blob exceeds remaining runtime quota".to_owned(),
                        )
                    } else {
                        (
                            "RESULT_TOO_LARGE",
                            format!("blob exceeds max_bytes={max_bytes}"),
                        )
                    };
                    return lua_error(lua, code, message, false);
                }
                let reference = match reservation.commit(output.stdout) {
                    Ok(reference) => reference,
                    Err(error) => return lua_error(lua, "BLOB_QUOTA_EXCEEDED", error, false),
                };
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
                let reservation = match capture_store.reserve(max_bytes) {
                    Ok(reservation) => reservation,
                    Err(error) => return lua_error(lua, "BLOB_QUOTA_EXCEEDED", error, false),
                };
                match crate::http::request_bytes(
                    &method,
                    &base_url,
                    &path,
                    &opts,
                    reservation.limit(),
                ) {
                    Ok(bytes) => match reservation.commit(bytes) {
                        Ok(reference) => {
                            Ok((Value::UserData(lua.create_userdata(reference)?), Value::Nil))
                        }
                        Err(error) => lua_error(lua, "BLOB_QUOTA_EXCEEDED", error, false),
                    },
                    Err(error)
                        if reservation.quota_limited() && error.code == "RESULT_TOO_LARGE" =>
                    {
                        lua_error(
                            lua,
                            "BLOB_QUOTA_EXCEEDED",
                            "blob exceeds remaining runtime quota".into(),
                            false,
                        )
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reservations_enforce_quota_before_capture_allocates() {
        let store = BlobStore::new();
        let reservation = store.reserve(MAX_TOTAL_BYTES).unwrap();
        assert!(store.reserve(1).is_err());
        drop(reservation);
        assert!(store.reserve(1).is_ok());
    }
}
