use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
};

use anyhow::{Context, Result, bail};
use mlua::{HookTriggers, Lua, LuaSerdeExt, MultiValue, Value, VmState};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue, json};

type StoreMap = HashMap<(String, String), JsonValue>;
static PERSISTENT_STORES: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<StoreMap>>>>> = OnceLock::new();

#[derive(Serialize, Deserialize)]
struct PersistedEntry {
    kind: String,
    key: String,
    value: JsonValue,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ExecutionMode {
    ReadOnly,
    Mutating,
}

impl ExecutionMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::ReadOnly => "readonly",
            Self::Mutating => "mutating",
        }
    }
}

pub struct Execution {
    pub output: String,
    pub result: JsonValue,
}

pub struct LuaRuntime {
    lua: Lua,
    output: Arc<Mutex<String>>,
    mode: Arc<Mutex<ExecutionMode>>,
    store: Arc<Mutex<StoreMap>>,
    cache_expiry: Arc<Mutex<HashMap<String, std::time::Instant>>>,
    allowed_cli: Arc<Mutex<Vec<String>>>,
    _vfs: Arc<tempfile::TempDir>,
    _exposures: Arc<Mutex<Vec<tempfile::TempDir>>>,
    _blobs: crate::blob::BlobStore,
    ingest: crate::ingest::IngestStore,
}

impl LuaRuntime {
    pub fn new(service_dir: Option<&Path>) -> Result<Self> {
        Self::build(service_dir, false, None, true)
    }

    pub fn new_with_options(service_dir: Option<&Path>, test_runtime: bool) -> Result<Self> {
        Self::build(service_dir, test_runtime, None, true)
    }

    pub fn new_persistent(service_dir: Option<&Path>, store_path: &Path) -> Result<Self> {
        Self::build(service_dir, false, Some(store_path), true)
    }

    pub(crate) fn new_mcp(service_dir: Option<&Path>, store_path: Option<&Path>) -> Result<Self> {
        Self::build(service_dir, false, store_path, false)
    }

    fn build(
        service_dir: Option<&Path>,
        test_runtime: bool,
        store_path: Option<&Path>,
        allow_direct_raw: bool,
    ) -> Result<Self> {
        let lua = unsafe { Lua::unsafe_new() };
        let vfs = Arc::new(
            tempfile::Builder::new()
                .prefix("luaris-mcp-vfs-")
                .tempdir()?,
        );
        let exposures = Arc::new(Mutex::new(Vec::new()));
        let blobs = crate::blob::BlobStore::new();
        let ingest = crate::ingest::IngestStore::new(Arc::clone(&vfs));
        let (store, store_path) = match store_path {
            Some(path) => {
                let path = absolute_path(path)?;
                (persistent_store(&path)?, Some(Arc::new(path)))
            }
            None => (Arc::new(Mutex::new(HashMap::new())), None),
        };
        let runtime = Self {
            lua,
            output: Arc::new(Mutex::new(String::new())),
            mode: Arc::new(Mutex::new(ExecutionMode::ReadOnly)),
            store,
            cache_expiry: Arc::new(Mutex::new(HashMap::new())),
            allowed_cli: Arc::new(Mutex::new(Vec::new())),
            _vfs: Arc::clone(&vfs),
            _exposures: Arc::clone(&exposures),
            _blobs: blobs.clone(),
            ingest: ingest.clone(),
        };
        runtime.install_core(vfs, exposures, blobs, ingest, store_path)?;
        if let Some(path) = service_dir {
            crate::services::load(&runtime.lua, path)?;
            runtime.discover_allowed_cli()?;
        }
        runtime.load_stored_snippets()?;
        runtime
            .lua
            .load("if _install_security_wrappers then _install_security_wrappers() end")
            .exec()?;
        runtime
            .lua
            .load("if _finish_raw_bootstrap then _finish_raw_bootstrap(...) end")
            .call::<()>(allow_direct_raw)?;
        runtime.restrict_stdlib(test_runtime)?;
        Ok(runtime)
    }

    fn install_core(
        &self,
        vfs: Arc<tempfile::TempDir>,
        exposures: Arc<Mutex<Vec<tempfile::TempDir>>>,
        blobs: crate::blob::BlobStore,
        ingest: crate::ingest::IngestStore,
        store_path: Option<Arc<PathBuf>>,
    ) -> Result<()> {
        let globals = self.lua.globals();
        let output = self.output.clone();
        globals.set(
            "print",
            self.lua.create_function(move |_, values: MultiValue| {
                let mut rendered = Vec::with_capacity(values.len());
                for value in values {
                    rendered.push(match value {
                        Value::String(s) => s.to_string_lossy().to_string(),
                        other => other.to_string()?,
                    });
                }
                let mut out = output.lock();
                out.push_str(&rendered.join("\t"));
                out.push('\n');
                Ok(())
            })?,
        )?;

        let raw = self.lua.create_table()?;
        let mode = self.mode.clone();
        raw.set(
            "exec_mode",
            self.lua
                .create_function(move |_, ()| Ok(mode.lock().as_str()))?,
        )?;
        for namespace in [
            "auth", "blob", "cli", "graphql", "http", "ingest", "secrets", "store", "task", "test",
            "url", "vfs",
        ] {
            raw.set(namespace, self.lua.create_table()?)?;
        }

        let unavailable = |name: &'static str| {
            self.lua.create_function(move |lua, _: MultiValue| {
                let error = lua.create_table()?;
                error.set("code", "NOT_IMPLEMENTED")?;
                error.set(
                    "message",
                    format!("{name} is not available in this runtime yet"),
                )?;
                error.set("recoverable", false)?;
                Ok((Value::Nil, error))
            })
        };
        let raw_table: mlua::Table = raw.clone();
        for (namespace, functions) in [
            ("blob", &["from_cli", "from_http", "len"][..]),
            ("cli", &["json", "start_json", "text"][..]),
            ("graphql", &["list", "request"][..]),
            ("http", &["list", "request"][..]),
            ("vfs", &["expose", "write_blob", "write_text"][..]),
        ] {
            let table: mlua::Table = raw_table.get(namespace)?;
            for function in functions {
                table.set(
                    *function,
                    unavailable(Box::leak(
                        format!("_raw.{namespace}.{function}").into_boxed_str(),
                    ))?,
                )?;
            }
        }

        crate::secrets::register(&self.lua, &raw_table, Arc::clone(&self.allowed_cli))?;

        let auth: mlua::Table = raw_table.get("auth")?;
        auth.set(
            "basic",
            self.lua
                .create_function(|lua, (username, password): (Value, Value)| {
                    let reference = lua.create_table()?;
                    reference.set("kind", "basic")?;
                    reference.set("username", username)?;
                    reference.set("password", password)?;
                    Ok(reference)
                })?,
        )?;
        auth.set(
            "bearer",
            self.lua.create_function(|lua, token: Value| {
                let reference = lua.create_table()?;
                reference.set("kind", "bearer")?;
                reference.set("token", token)?;
                Ok(reference)
            })?,
        )?;

        let url: mlua::Table = raw_table.get("url")?;
        url.set(
            "query_escape",
            self.lua.create_function(|_, value: String| {
                Ok(percent_encode(&value, UrlEncoding::Query))
            })?,
        )?;
        url.set(
            "path_escape",
            self.lua.create_function(|_, value: String| {
                Ok(percent_encode(&value, UrlEncoding::Path))
            })?,
        )?;
        url.set(
            "query_unescape",
            self.lua
                .create_function(|lua, value: String| match percent_decode(&value, true) {
                    Ok(decoded) => Ok((Value::String(lua.create_string(&decoded)?), Value::Nil)),
                    Err(message) => url_decode_error(lua, &value, message),
                })?,
        )?;
        url.set(
            "path_unescape",
            self.lua
                .create_function(|lua, value: String| match percent_decode(&value, false) {
                    Ok(decoded) => Ok((Value::String(lua.create_string(&decoded)?), Value::Nil)),
                    Err(message) => url_decode_error(lua, &value, message),
                })?,
        )?;
        let test_api: mlua::Table = raw_table.get("test")?;
        let mode = self.mode.clone();
        test_api.set(
            "set_mode",
            self.lua.create_function(move |_, value: String| {
                *mode.lock() = if value == "mutating" {
                    ExecutionMode::Mutating
                } else {
                    ExecutionMode::ReadOnly
                };
                Ok(true)
            })?,
        )?;

        let store_api: mlua::Table = raw_table.get("store")?;
        let store = Arc::clone(&self.store);
        store_api.set(
            "get",
            self.lua
                .create_function(move |lua, (kind, key): (String, String)| {
                    match store.lock().get(&(kind, key)).cloned() {
                        Some(value) => Ok((lua.to_value(&value)?, Value::Nil)),
                        None => Ok((Value::Nil, Value::Nil)),
                    }
                })?,
        )?;
        let store = Arc::clone(&self.store);
        let path = store_path.clone();
        store_api.set(
            "delete",
            self.lua
                .create_function(move |_, (kind, key): (String, String)| {
                    let mut values = store.lock();
                    let deleted = values.remove(&(kind, key)).is_some();
                    persist_if_configured(path.as_deref(), &values)
                        .map_err(mlua::Error::external)?;
                    Ok((deleted, Value::Nil))
                })?,
        )?;
        let store = Arc::clone(&self.store);
        store_api.set(
            "keys",
            self.lua.create_function(move |lua, kind: String| {
                let mut keys = store
                    .lock()
                    .keys()
                    .filter(|(entry_kind, _)| entry_kind == &kind)
                    .map(|(_, key)| key.clone())
                    .collect::<Vec<_>>();
                keys.sort();
                Ok((lua.to_value(&keys)?, Value::Nil))
            })?,
        )?;
        let store = Arc::clone(&self.store);
        store_api.set(
            "len",
            self.lua.create_function(move |_, kind: String| {
                let count = store
                    .lock()
                    .keys()
                    .filter(|(entry_kind, _)| entry_kind == &kind)
                    .count();
                Ok((count, Value::Nil))
            })?,
        )?;
        let store = Arc::clone(&self.store);
        let path = store_path.clone();
        store_api.set(
            "clear",
            self.lua.create_function(move |_, kind: String| {
                let mut values = store.lock();
                values.retain(|(entry_kind, _), _| entry_kind != &kind);
                persist_if_configured(path.as_deref(), &values).map_err(mlua::Error::external)?;
                Ok((true, Value::Nil))
            })?,
        )?;
        let store = Arc::clone(&self.store);
        let expiry = Arc::clone(&self.cache_expiry);
        let path = store_path.clone();
        store_api.set(
            "cache_set",
            self.lua
                .create_function(move |lua, (key, value, ttl): (String, Value, u64)| {
                    let value: JsonValue = lua.from_value(value)?;
                    let mut values = store.lock();
                    values.insert(("cache".into(), key.clone()), value);
                    persist_if_configured(path.as_deref(), &values)
                        .map_err(mlua::Error::external)?;
                    expiry.lock().insert(
                        key,
                        std::time::Instant::now() + std::time::Duration::from_secs(ttl),
                    );
                    Ok((true, Value::Nil))
                })?,
        )?;
        let store = Arc::clone(&self.store);
        let expiry = Arc::clone(&self.cache_expiry);
        let path = store_path.clone();
        store_api.set(
            "cache_get",
            self.lua.create_function(move |lua, key: String| {
                let expired = expiry
                    .lock()
                    .get(&key)
                    .is_some_and(|deadline| std::time::Instant::now() >= *deadline);
                if expired {
                    expiry.lock().remove(&key);
                    let mut values = store.lock();
                    values.remove(&("cache".into(), key));
                    persist_if_configured(path.as_deref(), &values)
                        .map_err(mlua::Error::external)?;
                    return Ok((Value::Nil, Value::Nil));
                }
                match store.lock().get(&("cache".into(), key)).cloned() {
                    Some(value) => Ok((lua.to_value(&value)?, Value::Nil)),
                    None => Ok((Value::Nil, Value::Nil)),
                }
            })?,
        )?;
        let store = Arc::clone(&self.store);
        let path = store_path;
        store_api.set(
            "put",
            self.lua
                .create_function(move |lua, (kind, key, value): (String, String, Value)| {
                    let value: JsonValue = lua.from_value(value)?;
                    let mut values = store.lock();
                    values.insert((kind, key), value);
                    persist_if_configured(path.as_deref(), &values)
                        .map_err(mlua::Error::external)?;
                    Ok((true, Value::Nil))
                })?,
        )?;

        let cli_api: mlua::Table = raw_table.get("cli")?;
        let allowed = Arc::clone(&self.allowed_cli);
        cli_api.set(
            "text",
            self.lua.create_function(
                move |lua, (tool, args, opts): (String, mlua::Table, Option<mlua::Table>)| {
                    run_cli(lua, &allowed, &tool, args, opts, false)
                },
            )?,
        )?;
        let allowed = Arc::clone(&self.allowed_cli);
        cli_api.set(
            "json",
            self.lua.create_function(
                move |lua, (tool, args, opts): (String, mlua::Table, Option<mlua::Table>)| {
                    run_cli(lua, &allowed, &tool, args, opts, true)
                },
            )?,
        )?;
        let tasks = crate::tasks::Manager::new();
        crate::http::register(&self.lua, &raw_table, tasks.clone())?;
        crate::ingest::register(&self.lua, &raw_table, ingest)?;
        crate::blob::register(
            &self.lua,
            &raw_table,
            blobs.clone(),
            Arc::clone(&self.allowed_cli),
        )?;
        crate::tasks::register(&self.lua, &raw_table, Arc::clone(&self.allowed_cli), tasks)?;
        crate::vfs::register(&self.lua, &raw_table, vfs, exposures, blobs)?;
        globals.set("_raw", raw)?;

        let json_api = self.lua.create_table()?;
        json_api.set(
            "encode",
            self.lua
                .create_function(|_, (value, pretty): (Value, Option<bool>)| {
                    let value = lua_value_to_json(value).map_err(mlua::Error::external)?;
                    let encoded = if pretty.unwrap_or(false) {
                        serde_json::to_string_pretty(&value)
                    } else {
                        serde_json::to_string(&value)
                    }
                    .map_err(mlua::Error::external)?;
                    Ok(encoded)
                })?,
        )?;
        json_api.set(
            "decode",
            self.lua.create_function(|lua, text: String| {
                let value: JsonValue =
                    serde_json::from_str(&text).map_err(mlua::Error::external)?;
                json_value_to_lua(lua, &value)
            })?,
        )?;
        json_api.set(
            "_empty_array",
            self.lua.create_function(|lua, ()| {
                let table = lua.create_table()?;
                let metatable = lua.create_table()?;
                metatable.set("__mcp_json_array", true)?;
                table.set_metatable(Some(metatable));
                Ok(table)
            })?,
        )?;
        json_api.set(
            "_mark_array",
            self.lua.create_function(|lua, table: mlua::Table| {
                let metatable = table.metatable().unwrap_or(lua.create_table()?);
                metatable.set("__mcp_json_array", true)?;
                table.set_metatable(Some(metatable));
                Ok(table)
            })?,
        )?;
        globals.set("json", json_api)?;

        let yaml_api = self.lua.create_table()?;
        yaml_api.set(
            "encode",
            self.lua.create_function(|lua, value: Value| {
                let value: JsonValue = lua.from_value(value)?;
                serde_yaml::to_string(&value).map_err(mlua::Error::external)
            })?,
        )?;
        yaml_api.set(
            "decode",
            self.lua.create_function(|lua, text: String| {
                let value: JsonValue =
                    serde_yaml::from_str(&text).map_err(mlua::Error::external)?;
                lua.to_value(&value)
            })?,
        )?;
        globals.set("yaml", yaml_api)?;

        globals.set("__runtime", self.lua.create_table()?)?;

        self.lua
            .load(include_str!("preload.lua"))
            .set_name("@core/preload.lua")
            .exec()?;
        for (name, source) in [
            ("@core/helpers.lua", include_str!("preload/helpers.lua")),
            ("@core/errutil.lua", include_str!("preload/errutil.lua")),
        ] {
            self.lua.load(source).set_name(name).exec()?;
        }
        let runtime_store: mlua::Table = self.lua.globals().get("store")?;
        self.lua
            .load(include_str!("preload/store.lua"))
            .set_name("@core/store.lua")
            .exec()?;
        let reference_store: mlua::Table = self.lua.globals().get("store")?;
        for pair in runtime_store.pairs::<String, Value>() {
            let (name, value) = pair?;
            if matches!(value, Value::Function(_)) {
                reference_store.set(name, value)?;
            }
        }
        self.lua
            .load(include_str!("preload/test.lua"))
            .set_name("@core/test.lua")
            .exec()?;
        let runtime_async_task: mlua::Table = self.lua.globals().get("async_task")?;
        self.lua
            .load(include_str!("preload/task.lua"))
            .set_name("@core/task.lua")
            .exec()?;
        let reference_async_task: mlua::Table = self.lua.globals().get("async_task")?;
        reference_async_task.set(
            "cancel",
            runtime_async_task.get::<mlua::Function>("cancel")?,
        )?;
        for (name, source) in [
            ("@core/vfs.lua", include_str!("preload/vfs.lua")),
            ("@core/ingest.lua", include_str!("preload/ingest.lua")),
            (
                "@core/capabilities.lua",
                include_str!("preload/capabilities.lua"),
            ),
        ] {
            self.lua.load(source).set_name(name).exec()?;
        }
        self.lua
            .load("if _install_raw_guards then _install_raw_guards() end")
            .exec()?;
        Ok(())
    }

    fn discover_allowed_cli(&self) -> Result<()> {
        let globals = self.lua.globals();
        let mut commands = Vec::new();
        for pair in globals.pairs::<Value, Value>() {
            let (_, value) = pair?;
            let Value::Table(namespace) = value else {
                continue;
            };
            let Ok(list) = namespace.get::<mlua::Table>("__allowed_cli_commands") else {
                continue;
            };
            for command in list.sequence_values::<String>() {
                commands.push(command?);
            }
        }
        commands.sort();
        commands.dedup();
        *self.allowed_cli.lock() = commands;
        Ok(())
    }

    fn restrict_stdlib(&self, test_runtime: bool) -> Result<()> {
        if test_runtime {
            return Ok(());
        }
        self.lua
            .load(
                r#"
                io = nil
                if package and package.loaded then
                  package.loaded.io = nil
                  package.loaded.os = nil
                end
                if os then
                  local restricted = {}
                  for key, value in pairs(os) do restricted[key] = value end
                  for _, key in ipairs({"execute","getenv","remove","rename","setenv","tmpname","exit"}) do restricted[key] = nil end
                  os = restricted
                end
                local original_require = require
                require = function(name)
                  if name == "io" or name == "os" then error("module " .. name .. " is disabled", 2) end
                  return original_require(name)
                end
                debug = nil
                "#,
            )
            .exec()?;
        Ok(())
    }

    fn load_stored_snippets(&self) -> Result<()> {
        self.lua
            .load(
                r#"
                local function restore(kind)
                  local keys, keys_err = _raw.store.keys(kind)
                  if keys_err then error(keys_err.message) end
                  for _, key in ipairs(keys) do
                    local value, get_err = _raw.store.get(kind, key)
                    if get_err then error(get_err.message) end
                    local ok, put_err = store.put(kind, key, value, {content_type="lua"})
                    if not ok then error(put_err.message) end
                  end
                end
                restore("fn")
                restore("schema")
                restore("example")
                "#,
            )
            .set_name("@core/restore-store.lua")
            .exec()
            .context("failed to restore persisted Lua snippets")
    }

    pub fn execute(&self, code: &str, mode: ExecutionMode, chunk_name: &str) -> Result<Execution> {
        self.execute_with_timeout(code, mode, chunk_name, None)
    }

    pub fn execute_with_timeout(
        &self,
        code: &str,
        mode: ExecutionMode,
        chunk_name: &str,
        timeout: Option<std::time::Duration>,
    ) -> Result<Execution> {
        if code.trim().is_empty() {
            bail!("Lua code is required on stdin");
        }
        *self.mode.lock() = mode;
        self.output.lock().clear();
        if let Some(timeout) = timeout {
            let deadline = std::time::Instant::now() + timeout;
            self.lua.set_hook(
                HookTriggers::new().every_nth_instruction(10_000),
                move |_, _| {
                    if std::time::Instant::now() >= deadline {
                        return Err(mlua::Error::runtime(format!(
                            "execution timeout after {}ms - increase timeout_ms or optimize script",
                            timeout.as_millis()
                        )));
                    }
                    Ok(VmState::Continue)
                },
            );
        }
        let _deadline = crate::deadline::enter(timeout);
        let evaluation: mlua::Result<MultiValue> = self.lua.load(code).set_name(chunk_name).eval();
        self.lua.remove_hook();
        let values = evaluation.with_context(|| format!("Lua execution failed in {chunk_name}"))?;
        let mut results = values
            .into_iter()
            .map(|value| {
                lua_value_to_json(value.clone())
                    .unwrap_or_else(|_| json!(value.to_string().unwrap_or_default()))
            })
            .collect::<Vec<JsonValue>>();
        while results.last().is_some_and(JsonValue::is_null) {
            results.pop();
        }
        let result = match results.len() {
            0 => JsonValue::Null,
            1 => results.pop().expect("one result"),
            _ => JsonValue::Array(results),
        };
        Ok(Execution {
            output: self.output.lock().clone(),
            result,
        })
    }

    pub fn list_raw_primitives(&self) -> Result<Vec<(String, Vec<String>)>> {
        let raw: mlua::Table = self.lua.globals().get("_raw")?;
        let mut namespaces = Vec::new();
        let mut root_functions = Vec::new();
        for pair in raw.pairs::<String, Value>() {
            let (name, value) = pair?;
            match value {
                Value::Function(_) => root_functions.push(name),
                Value::Table(table) => {
                    let mut functions = Vec::new();
                    for child in table.pairs::<String, Value>() {
                        let (child_name, child_value) = child?;
                        if matches!(child_value, Value::Function(_)) {
                            functions.push(child_name);
                        }
                    }
                    if !functions.is_empty() {
                        functions.sort();
                        namespaces.push((format!("_raw.{name}"), functions));
                    }
                }
                _ => {}
            }
        }
        if !root_functions.is_empty() {
            root_functions.sort();
            namespaces.push(("_raw".to_owned(), root_functions));
        }
        namespaces.sort_by(|left, right| left.0.cmp(&right.0));
        Ok(namespaces)
    }

    pub fn eligible_function_paths(&self) -> Result<Vec<String>> {
        let globals = self.lua.globals();
        let mut out = Vec::new();
        let mut seen = Vec::new();
        for pair in globals.pairs::<Value, Value>() {
            let (_, value) = pair?;
            self.collect_schema_function_paths(value, &mut seen, &mut out)?;
        }
        out.sort();
        out.dedup();
        Ok(out)
    }

    fn collect_schema_function_paths(
        &self,
        value: Value,
        seen: &mut Vec<mlua::Table>,
        out: &mut Vec<String>,
    ) -> Result<()> {
        let Value::Table(table) = value else {
            return Ok(());
        };
        if seen.iter().any(|existing| existing == &table) {
            return Ok(());
        }
        seen.push(table.clone());

        if let Ok(schema) = table.get::<mlua::Table>("__schema") {
            let namespace = schema.get::<Option<String>>("namespace")?;
            if let Some(namespace) = namespace.filter(|namespace| !namespace.starts_with("__")) {
                if let Ok(functions) = schema.get::<mlua::Table>("functions") {
                    for descriptor in functions.sequence_values::<mlua::Table>() {
                        let descriptor = descriptor?;
                        let name = descriptor.get::<Option<String>>("name")?;
                        if let Some(name) = name.filter(|name| !name.is_empty()) {
                            let path = descriptor
                                .get::<Option<String>>("path")?
                                .filter(|path| !path.is_empty())
                                .unwrap_or_else(|| format!("{namespace}.{name}"));
                            out.push(path);
                        }
                    }
                }
            }
        }

        for pair in table.pairs::<Value, Value>() {
            let (key, child) = pair?;
            if matches!(key, Value::String(ref key) if key.as_bytes() == b"__schema") {
                continue;
            }
            if matches!(child, Value::Table(_)) {
                self.collect_schema_function_paths(child, seen, out)?;
            }
        }
        Ok(())
    }

    pub fn ingest_text(&self, text: &str) -> Result<String> {
        self.ingest.store(text).map_err(anyhow::Error::msg)
    }

    pub(crate) fn captured_output(&self) -> String {
        self.output.lock().clone()
    }

    pub(crate) fn set_server_id(&self, server_id: &str) -> Result<()> {
        let runtime: mlua::Table = self.lua.globals().get("__runtime")?;
        runtime.set("server_id", server_id)?;
        Ok(())
    }
}

fn persistent_store(path: &Path) -> Result<Arc<Mutex<StoreMap>>> {
    let path = absolute_path(path)?;
    let stores = PERSISTENT_STORES.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(store) = stores.lock().get(&path).cloned() {
        return Ok(store);
    }

    let values = if path.exists() {
        let bytes =
            fs::read(&path).with_context(|| format!("failed to read store {}", path.display()))?;
        let entries: Vec<PersistedEntry> = serde_json::from_slice(&bytes)
            .with_context(|| format!("failed to parse store {}", path.display()))?;
        entries
            .into_iter()
            .filter(|entry| entry.kind != "cache")
            .map(|entry| ((entry.kind, entry.key), entry.value))
            .collect()
    } else {
        HashMap::new()
    };
    let store = Arc::new(Mutex::new(values));
    let mut stores = stores.lock();
    Ok(stores
        .entry(path)
        .or_insert_with(|| Arc::clone(&store))
        .clone())
}

fn absolute_path(path: &Path) -> Result<PathBuf> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn persist_if_configured(path: Option<&PathBuf>, values: &StoreMap) -> std::io::Result<()> {
    let Some(path) = path else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        let parent_existed = parent.exists();
        fs::create_dir_all(parent)?;
        #[cfg(unix)]
        if !parent_existed {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
        }
    }

    let mut entries = values
        .iter()
        .filter(|((kind, _), _)| kind != "cache")
        .map(|((kind, key), value)| PersistedEntry {
            kind: kind.clone(),
            key: key.clone(),
            value: value.clone(),
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| (&left.kind, &left.key).cmp(&(&right.kind, &right.key)));
    let encoded = serde_json::to_vec_pretty(&entries).map_err(std::io::Error::other)?;
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, encoded)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(temporary, path)
}

fn lua_value_to_json(value: Value) -> Result<JsonValue> {
    match value {
        Value::Nil => Ok(JsonValue::Null),
        Value::Boolean(value) => Ok(JsonValue::Bool(value)),
        Value::Integer(value) => Ok(JsonValue::Number(value.into())),
        Value::Number(value) => JsonNumber::from_f64(value)
            .map(JsonValue::Number)
            .ok_or_else(|| anyhow::anyhow!("cannot encode non-finite number as JSON")),
        Value::String(value) => Ok(JsonValue::String(value.to_string_lossy().to_string())),
        Value::Table(table) => lua_table_to_json(table),
        Value::LightUserData(data) if data.0.is_null() => Ok(JsonValue::Null),
        other => bail!("cannot encode Lua {} as JSON", other.type_name()),
    }
}

fn lua_table_to_json(table: mlua::Table) -> Result<JsonValue> {
    if is_marked_json_array(&table) {
        let len = table
            .raw_get::<Option<usize>>("n")?
            .unwrap_or_else(|| table.raw_len());
        let mut values = Vec::with_capacity(len);
        for index in 1..=len {
            values.push(lua_value_to_json(table.raw_get::<Value>(index)?)?);
        }
        return Ok(JsonValue::Array(values));
    }

    let mut entries = Vec::new();
    for pair in table.pairs::<Value, Value>() {
        entries.push(pair?);
    }

    if entries.is_empty() {
        return Ok(JsonValue::Object(JsonMap::new()));
    }

    if let Some(len) = contiguous_array_len(&entries) {
        let mut values = Vec::with_capacity(len);
        for index in 1..=len {
            values.push(lua_value_to_json(table.raw_get::<Value>(index)?)?);
        }
        return Ok(JsonValue::Array(values));
    }

    let mut object = JsonMap::new();
    for (key, value) in entries {
        object.insert(lua_key_to_json_object_key(key)?, lua_value_to_json(value)?);
    }
    Ok(JsonValue::Object(object))
}

fn is_marked_json_array(table: &mlua::Table) -> bool {
    table
        .metatable()
        .and_then(|metatable| metatable.raw_get::<Option<bool>>("__mcp_json_array").ok())
        .flatten()
        == Some(true)
}

fn contiguous_array_len(entries: &[(Value, Value)]) -> Option<usize> {
    let mut indexes = Vec::with_capacity(entries.len());
    for (key, _) in entries {
        let Value::Integer(index) = key else {
            return None;
        };
        if *index < 1 {
            return None;
        }
        indexes.push(*index as usize);
    }
    indexes.sort_unstable();
    indexes
        .iter()
        .enumerate()
        .all(|(offset, index)| *index == offset + 1)
        .then_some(indexes.len())
}

fn lua_key_to_json_object_key(key: Value) -> Result<String> {
    match key {
        Value::String(value) => Ok(value.to_string_lossy().to_string()),
        Value::Integer(value) => Ok(value.to_string()),
        Value::Number(value) => Ok(value.to_string()),
        Value::Boolean(value) => Ok(value.to_string()),
        other => bail!(
            "cannot encode Lua {} table key as JSON object key",
            other.type_name()
        ),
    }
}

fn json_value_to_lua(lua: &Lua, value: &JsonValue) -> mlua::Result<Value> {
    match value {
        JsonValue::Null => Ok(Value::NULL),
        JsonValue::Bool(value) => Ok(Value::Boolean(*value)),
        JsonValue::Number(value) => {
            if let Some(integer) = value.as_i64() {
                Ok(Value::Integer(integer))
            } else if let Some(number) = value.as_f64() {
                Ok(Value::Number(number))
            } else {
                Err(mlua::Error::external("JSON number is out of range"))
            }
        }
        JsonValue::String(value) => Ok(Value::String(lua.create_string(value)?)),
        JsonValue::Array(values) => {
            let table = lua.create_table()?;
            for (index, value) in values.iter().enumerate() {
                table.raw_set(index + 1, json_value_to_lua(lua, value)?)?;
            }
            table.raw_set("n", values.len())?;
            mark_json_array_table(lua, &table)?;
            Ok(Value::Table(table))
        }
        JsonValue::Object(values) => {
            let table = lua.create_table()?;
            for (key, value) in values {
                table.raw_set(key.as_str(), json_value_to_lua(lua, value)?)?;
            }
            Ok(Value::Table(table))
        }
    }
}

fn mark_json_array_table(lua: &Lua, table: &mlua::Table) -> mlua::Result<()> {
    let metatable = table.metatable().unwrap_or(lua.create_table()?);
    metatable.raw_set("__mcp_json_array", true)?;
    table.set_metatable(Some(metatable));
    Ok(())
}

fn run_cli(
    lua: &Lua,
    allowed: &Arc<Mutex<Vec<String>>>,
    tool: &str,
    args: mlua::Table,
    opts: Option<mlua::Table>,
    parse_json: bool,
) -> mlua::Result<(Value, Value)> {
    if !allowed.lock().iter().any(|candidate| candidate == tool) {
        return lua_error(
            lua,
            "CLI_NOT_ALLOWED",
            format!("CLI command '{tool}' is not allowed"),
            false,
        );
    }
    let mut command = std::process::Command::new(tool);
    for value in args.sequence_values::<Value>() {
        command.arg(match value? {
            Value::String(value) => value.to_string_lossy().to_string(),
            value => value.to_string()?,
        });
    }
    if let Some(opts) = opts.as_ref()
        && let Ok(cwd) = opts.get::<String>("cwd")
    {
        command.current_dir(cwd);
    }
    let timeout = opts
        .as_ref()
        .and_then(|opts| opts.get::<f64>("timeout").ok())
        .filter(|timeout| timeout.is_finite() && *timeout > 0.0)
        .unwrap_or(60.0);
    let Some(timeout) = crate::deadline::effective(std::time::Duration::from_secs_f64(timeout))
    else {
        return lua_error(lua, "TIMEOUT", "execution deadline exceeded".into(), true);
    };
    let output = match crate::process::capture(&mut command, timeout, 200 * 1024 * 1024) {
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
    if output.stdout_exceeded {
        return lua_error(
            lua,
            "RESULT_TOO_LARGE",
            "CLI output exceeded 209715200 bytes".into(),
            false,
        );
    }
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        return lua_error(
            lua,
            "CLI_ERROR",
            if detail.is_empty() {
                format!("command exited with {}", output.status)
            } else {
                detail
            },
            false,
        );
    }
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    if !parse_json {
        return Ok((Value::String(lua.create_string(&stdout)?), Value::Nil));
    }
    let decoded: JsonValue = match serde_json::from_str(&stdout) {
        Ok(value) => value,
        Err(error) => {
            return lua_error(
                lua,
                "CLI_ERROR",
                format!("failed to parse JSON: {error}"),
                true,
            );
        }
    };
    Ok((lua.to_value(&decoded)?, Value::Nil))
}

pub(crate) fn lua_error(
    lua: &Lua,
    code: &str,
    message: String,
    recoverable: bool,
) -> mlua::Result<(Value, Value)> {
    let error = lua.create_table()?;
    error.set("code", code)?;
    error.set("message", message)?;
    error.set("context", lua.create_table()?)?;
    error.set("recoverable", recoverable)?;
    Ok((Value::Nil, Value::Table(error)))
}

enum UrlEncoding {
    Query,
    Path,
}

fn percent_encode(value: &str, encoding: UrlEncoding) -> String {
    let mut output = String::new();
    for byte in value.bytes() {
        if matches!(encoding, UrlEncoding::Query) && byte == b' ' {
            output.push('+');
            continue;
        }
        let unreserved = byte.is_ascii_alphanumeric()
            || matches!(byte, b'-' | b'_' | b'.' | b'~')
            || (matches!(encoding, UrlEncoding::Path) && byte == b'+');
        if unreserved {
            output.push(byte as char);
        } else {
            output.push_str(&format!("%{byte:02X}"));
        }
    }
    output
}

fn percent_decode(value: &str, plus_as_space: bool) -> std::result::Result<String, String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'+' if plus_as_space => {
                decoded.push(b' ');
                index += 1;
            }
            b'%' => {
                if index + 2 >= bytes.len() {
                    return Err("incomplete percent escape".into());
                }
                let high = hex_digit(bytes[index + 1])
                    .ok_or_else(|| "invalid percent escape".to_owned())?;
                let low = hex_digit(bytes[index + 2])
                    .ok_or_else(|| "invalid percent escape".to_owned())?;
                decoded.push((high << 4) | low);
                index += 3;
            }
            byte => {
                decoded.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8(decoded).map_err(|_| "decoded value is not valid UTF-8".into())
}

fn hex_digit(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn url_decode_error(lua: &Lua, value: &str, message: String) -> mlua::Result<(Value, Value)> {
    let error = lua.create_table()?;
    error.set("code", "VALIDATION")?;
    error.set("message", message)?;
    error.set("recoverable", false)?;
    let context = lua.create_table()?;
    context.set("value", value)?;
    error.set("context", context)?;
    Ok((Value::Nil, Value::Table(error)))
}

pub fn read_script(path: Option<&Path>) -> Result<String> {
    match path {
        Some(path) => {
            fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))
        }
        None => {
            use std::io::Read;
            let mut code = String::new();
            std::io::stdin().read_to_string(&mut code)?;
            Ok(code)
        }
    }
}
