use std::{
    collections::HashMap,
    fs,
    path::Path,
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, bail};
use mlua::{Lua, LuaSerdeExt, MultiValue, Value};
use parking_lot::Mutex;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

use crate::runtime::lua_error;

const MAX_NAME_BYTES: usize = 1_024;
const MAX_SOURCE_BYTES: usize = 10 * 1024 * 1024;

#[derive(Clone)]
pub struct Store {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Snippet {
    pub path: String,
    pub code: String,
    pub schema_source: Option<String>,
    pub example_source: Option<String>,
    pub description: String,
    pub created_at_s: i64,
    pub updated_at_s: i64,
}

#[derive(Clone, Debug)]
pub struct Metric {
    pub name: String,
    pub value: f64,
}

impl Store {
    /// A missing path is intentionally an isolated in-memory store for library
    /// runtimes. The CLI and MCP server always supply their resolved DB path.
    pub fn open(path: Option<&Path>) -> Result<Self> {
        // Store ownership is runtime/application scoped. SQLite WAL handles
        // cross-runtime and cross-process coordination without an unbounded
        // process-global connection registry.
        let connection = match path {
            Some(path) => Arc::new(Mutex::new(open_connection(Some(path))?)),
            None => Arc::new(Mutex::new(open_connection(None)?)),
        };
        Ok(Self { connection })
    }

    pub fn put_kv(
        &self,
        namespace: &str,
        key: &str,
        value: &JsonValue,
        content_type: &str,
        created_at_s: Option<i64>,
        expires_at_s: Option<i64>,
    ) -> Result<()> {
        validate_name("namespace", namespace)?;
        validate_name("key", key)?;
        validate_name("content type", content_type)?;
        let encoded = serde_json::to_string(value).context("failed to serialize KV value")?;
        validate_source("serialized KV value", &encoded)?;
        let created_at_s = created_at_s
            .filter(|value| *value != 0)
            .unwrap_or_else(now_s);
        self.connection.lock().execute(
            "INSERT INTO kv_entries(namespace, key, value, content_type, created_at_s, expires_at_s)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(namespace, key) DO UPDATE SET
               value=excluded.value, content_type=excluded.content_type,
               created_at_s=excluded.created_at_s, expires_at_s=excluded.expires_at_s",
            params![namespace, key, encoded, content_type, created_at_s, expires_at_s],
        )?;
        Ok(())
    }

    pub fn get_kv(&self, namespace: &str, key: &str) -> Result<Option<JsonValue>> {
        validate_name("namespace", namespace)?;
        validate_name("key", key)?;
        let now = now_s();
        let connection = self.connection.lock();
        // Expiry cleanup is deliberately lazy and best-effort. A failed cleanup
        // must not make an already-expired row visible.
        let _ = connection.execute(
            "DELETE FROM kv_entries WHERE namespace=?1 AND expires_at_s IS NOT NULL AND expires_at_s <= ?2",
            params![namespace, now],
        );
        let encoded: Option<String> = connection
            .query_row(
                "SELECT value FROM kv_entries
             WHERE namespace=?1 AND key=?2 AND (expires_at_s IS NULL OR expires_at_s > ?3)",
                params![namespace, key, now],
                |row| row.get(0),
            )
            .optional()?;
        encoded
            .map(|value| serde_json::from_str(&value).context("failed to deserialize KV value"))
            .transpose()
    }

    pub fn delete_kv(&self, namespace: &str, key: &str) -> Result<bool> {
        validate_name("namespace", namespace)?;
        validate_name("key", key)?;
        Ok(self.connection.lock().execute(
            "DELETE FROM kv_entries WHERE namespace=?1 AND key=?2",
            params![namespace, key],
        )? > 0)
    }

    pub fn keys_kv(&self, namespace: &str) -> Result<Vec<String>> {
        validate_name("namespace", namespace)?;
        let now = now_s();
        let connection = self.connection.lock();
        let _ = connection.execute(
            "DELETE FROM kv_entries WHERE namespace=?1 AND expires_at_s IS NOT NULL AND expires_at_s <= ?2",
            params![namespace, now],
        );
        let mut statement = connection.prepare(
            "SELECT key FROM kv_entries WHERE namespace=?1 AND (expires_at_s IS NULL OR expires_at_s > ?2) ORDER BY key",
        )?;
        statement
            .query_map(params![namespace, now], |row| row.get(0))?
            .collect::<rusqlite::Result<_>>()
            .map_err(Into::into)
    }

    pub fn count_kv(&self, namespace: &str) -> Result<i64> {
        validate_name("namespace", namespace)?;
        let now = now_s();
        let connection = self.connection.lock();
        let _ = connection.execute(
            "DELETE FROM kv_entries WHERE namespace=?1 AND expires_at_s IS NOT NULL AND expires_at_s <= ?2",
            params![namespace, now],
        );
        Ok(connection.query_row(
            "SELECT COUNT(*) FROM kv_entries WHERE namespace=?1 AND (expires_at_s IS NULL OR expires_at_s > ?2)",
            params![namespace, now], |row| row.get(0),
        )?)
    }

    pub fn clear_kv(&self, namespace: &str) -> Result<()> {
        validate_name("namespace", namespace)?;
        self.connection.lock().execute(
            "DELETE FROM kv_entries WHERE namespace=?1",
            params![namespace],
        )?;
        Ok(())
    }

    pub fn increment_function_metric(&self, operation: &str, outcome: &str) -> Result<f64> {
        self.increment_metric(&format!("fn.{operation}.{outcome}"), 1.0)
    }

    pub fn increment_metric(&self, name: &str, delta: f64) -> Result<f64> {
        validate_name("metric name", name)?;
        if !delta.is_finite() {
            bail!("invalid metric delta")
        }
        let now = now_s();
        Ok(self.connection.lock().query_row(
            "INSERT INTO metrics(name, value, created_at_s, updated_at_s) VALUES(?1, ?2, ?3, ?3)
             ON CONFLICT(name) DO UPDATE SET value=metrics.value + excluded.value, updated_at_s=excluded.updated_at_s
             RETURNING value",
            params![name, delta, now], |row| row.get(0),
        )?)
    }

    /// Atomically apply a group of wrapper metrics. Callers aggregate within an
    /// execution and flush at its boundary, reducing SQLite lock contention in
    /// high-frequency Lua loops without weakening durable metric semantics.
    pub fn increment_metrics_batch(&self, metrics: &HashMap<String, f64>) -> Result<()> {
        if metrics.is_empty() {
            return Ok(());
        }
        let now = now_s();
        let mut connection = self.connection.lock();
        let transaction = connection.transaction()?;
        for (name, delta) in metrics {
            validate_name("metric name", name)?;
            if !delta.is_finite() {
                bail!("invalid metric delta");
            }
            transaction.execute(
                "INSERT INTO metrics(name, value, created_at_s, updated_at_s) VALUES(?1, ?2, ?3, ?3)
                 ON CONFLICT(name) DO UPDATE SET value=metrics.value + excluded.value, updated_at_s=excluded.updated_at_s",
                params![name, delta, now],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn list_metrics(&self) -> Result<Vec<Metric>> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare("SELECT name, value FROM metrics ORDER BY name")?;
        statement
            .query_map([], |row| {
                Ok(Metric {
                    name: row.get(0)?,
                    value: row.get(1)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()
            .map_err(Into::into)
    }

    pub fn save_snippet(
        &self,
        path: &str,
        code: &str,
        schema_source: Option<&str>,
        example_source: Option<&str>,
        description: Option<&str>,
    ) -> Result<()> {
        validate_name("snippet path", path)?;
        validate_source("snippet code", code)?;
        if let Some(source) = schema_source {
            validate_source("snippet schema source", source)?;
        }
        if let Some(source) = example_source {
            validate_source("snippet example source", source)?;
        }
        let now = now_s();
        self.connection.lock().execute(
            "INSERT INTO snippets(path, code, schema_source, example_source, description, created_at_s, updated_at_s)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?6)
             ON CONFLICT(path) DO UPDATE SET code=excluded.code, schema_source=excluded.schema_source,
               example_source=excluded.example_source, description=excluded.description, updated_at_s=excluded.updated_at_s",
            params![path, code, schema_source, example_source, description.unwrap_or(""), now],
        )?;
        Ok(())
    }

    pub fn get_snippet(&self, path: &str) -> Result<Option<Snippet>> {
        validate_name("snippet path", path)?;
        self.connection.lock().query_row(
            "SELECT path, code, schema_source, example_source, description, created_at_s, updated_at_s FROM snippets WHERE path=?1",
            params![path], snippet_from_row,
        ).optional().map_err(Into::into)
    }

    pub fn list_snippets(&self) -> Result<Vec<Snippet>> {
        let connection = self.connection.lock();
        let mut statement = connection.prepare(
            "SELECT path, code, schema_source, example_source, description, created_at_s, updated_at_s FROM snippets ORDER BY path",
        )?;
        statement
            .query_map([], snippet_from_row)?
            .collect::<rusqlite::Result<_>>()
            .map_err(Into::into)
    }

    pub fn delete_snippet(&self, path: &str) -> Result<bool> {
        validate_name("snippet path", path)?;
        Ok(self
            .connection
            .lock()
            .execute("DELETE FROM snippets WHERE path=?1", params![path])?
            > 0)
    }
}

fn snippet_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Snippet> {
    Ok(Snippet {
        path: row.get(0)?,
        code: row.get(1)?,
        schema_source: row.get(2)?,
        example_source: row.get(3)?,
        description: row.get(4)?,
        created_at_s: row.get(5)?,
        updated_at_s: row.get(6)?,
    })
}

fn open_connection(path: Option<&Path>) -> Result<Connection> {
    if let Some(path) = path {
        if let Some(parent) = path.parent() {
            let existed = parent.exists();
            fs::create_dir_all(parent)?;
            #[cfg(unix)]
            if !existed {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
            }
        }
    }
    let mut connection = match path {
        Some(path) => Connection::open(path),
        None => Connection::open_in_memory(),
    }?;
    connection.busy_timeout(std::time::Duration::from_secs(10))?;
    connection.pragma_update(None, "journal_mode", "WAL")?;
    connection.pragma_update(None, "synchronous", "NORMAL")?;
    connection.pragma_update(None, "cache_size", -65_536i64)?;
    connection.pragma_update(None, "temp_store", "MEMORY")?;
    connection.pragma_update(None, "foreign_keys", "ON")?;
    let transaction = connection.transaction()?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS kv_entries (
            namespace TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL, content_type TEXT NOT NULL,
            created_at_s INTEGER NOT NULL, expires_at_s INTEGER, PRIMARY KEY(namespace, key)
          );
          CREATE INDEX IF NOT EXISTS kv_entries_expires_at_idx ON kv_entries(expires_at_s);
          CREATE TABLE IF NOT EXISTS metrics (
            name TEXT PRIMARY KEY, value REAL NOT NULL, created_at_s INTEGER NOT NULL, updated_at_s INTEGER NOT NULL
          );
          CREATE TABLE IF NOT EXISTS snippets (
            path TEXT PRIMARY KEY, code TEXT NOT NULL, schema_source TEXT, example_source TEXT,
            description TEXT NOT NULL DEFAULT '', created_at_s INTEGER NOT NULL, updated_at_s INTEGER NOT NULL
          );",
    )?;
    migrate_legacy_entries(&transaction)?;
    transaction.commit()?;
    #[cfg(unix)]
    if let Some(path) = path {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    Ok(connection)
}

/// Migrates the short-lived pre-SQLite `entries` table when present. The old
/// table is dropped only in this transaction after every new row is written.
fn migrate_legacy_entries(transaction: &Transaction<'_>) -> Result<()> {
    let exists: bool = transaction.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='entries')",
        [],
        |row| row.get(0),
    )?;
    if !exists {
        return Ok(());
    }
    let mut columns = transaction.prepare("PRAGMA table_info(entries)")?;
    let names = columns
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(columns);
    let kind_column = if names.iter().any(|name| name == "kind") {
        "kind"
    } else if names.iter().any(|name| name == "namespace") {
        "namespace"
    } else {
        bail!("legacy entries table has no kind/namespace column")
    };
    if !names.iter().any(|name| name == "key") || !names.iter().any(|name| name == "value") {
        bail!("legacy entries table is missing key or value")
    }
    let expiry = if names.iter().any(|name| name == "expires_at_s") {
        "expires_at_s"
    } else {
        "NULL"
    };
    let query = format!("SELECT {kind_column}, key, value, {expiry} FROM entries");
    let mut statement = transaction.prepare(&query)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, Option<i64>>(3)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    drop(statement);

    let mut snippets = HashMap::<String, (Option<String>, Option<String>, Option<String>)>::new();
    for (kind, key, value, expires_at_s) in rows {
        match kind.as_str() {
            "fn" => snippets.entry(key).or_default().0 = Some(legacy_text(&value)?),
            "schema" => snippets.entry(key).or_default().1 = Some(legacy_text(&value)?),
            "example" => snippets.entry(key).or_default().2 = Some(legacy_text(&value)?),
            "metrics" => {
                let value = legacy_json(&value)?
                    .as_f64()
                    .filter(|value| value.is_finite())
                    .ok_or_else(|| {
                        anyhow::anyhow!("legacy metric {key:?} is not finite numeric JSON")
                    })?;
                let now = now_s();
                transaction.execute(
                    "INSERT INTO metrics(name, value, created_at_s, updated_at_s) VALUES(?1, ?2, ?3, ?3)
                     ON CONFLICT(name) DO UPDATE SET value=excluded.value, updated_at_s=excluded.updated_at_s",
                    params![key, value, now],
                )?;
            }
            namespace => {
                let namespace = namespace.strip_prefix("kv:").unwrap_or(namespace);
                validate_name("legacy namespace", namespace)?;
                validate_name("legacy key", &key)?;
                let encoded = serde_json::to_string(&legacy_json(&value)?)?;
                let now = now_s();
                transaction.execute(
                    "INSERT INTO kv_entries(namespace, key, value, content_type, created_at_s, expires_at_s)
                     VALUES(?1, ?2, ?3, 'json', ?4, ?5)
                     ON CONFLICT(namespace, key) DO UPDATE SET value=excluded.value, content_type=excluded.content_type,
                       created_at_s=excluded.created_at_s, expires_at_s=excluded.expires_at_s",
                    params![namespace, key, encoded, now, expires_at_s],
                )?;
            }
        }
    }
    for (path, (code, schema, example)) in snippets {
        let Some(code) = code else {
            bail!("legacy snippet metadata has no function source for {path}")
        };
        validate_name("legacy snippet path", &path)?;
        validate_source("legacy snippet code", &code)?;
        let now = now_s();
        transaction.execute(
            "INSERT INTO snippets(path, code, schema_source, example_source, description, created_at_s, updated_at_s)
             VALUES(?1, ?2, ?3, ?4, '', ?5, ?5)",
            params![path, code, schema, example, now],
        )?;
    }
    transaction.execute("DROP TABLE entries", [])?;
    Ok(())
}

fn legacy_json(value: &str) -> Result<JsonValue> {
    serde_json::from_str(value).or_else(|_| Ok(JsonValue::String(value.to_owned())))
}

fn legacy_text(value: &str) -> Result<String> {
    Ok(legacy_json(value)?.as_str().unwrap_or(value).to_owned())
}

fn validate_name(label: &str, value: &str) -> Result<()> {
    if value.is_empty() {
        bail!("{label} is empty")
    }
    if value.len() > MAX_NAME_BYTES {
        bail!("{label} exceeds {MAX_NAME_BYTES} bytes")
    }
    Ok(())
}

fn validate_source(label: &str, value: &str) -> Result<()> {
    if value.is_empty() {
        bail!("{label} is empty")
    }
    if value.len() > MAX_SOURCE_BYTES {
        bail!("{label} exceeds {MAX_SOURCE_BYTES} bytes")
    }
    Ok(())
}

fn now_s() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

/// Restores persisted snippets before their public-function wrappers are
/// registered. MCP runtimes provide the restricted session environment so
/// restored snippet closures cannot retain trusted bootstrap globals.
pub(crate) fn restore_lua_snippets(
    lua: &Lua,
    store: &Store,
    environment: Option<mlua::Table>,
) -> Result<()> {
    let restore: mlua::Function = lua.globals().get("__restore_snippet")?;
    for snippet in store.list_snippets()? {
        let definition = lua.create_table()?;
        definition.set("path", snippet.path)?;
        definition.set("code", snippet.code)?;
        definition.set("schema_expr", snippet.schema_source)?;
        definition.set("example", snippet.example_source)?;
        definition.set("description", snippet.description)?;
        let values: MultiValue = match &environment {
            Some(environment) => restore.call((definition, environment.clone()))?,
            None => restore.call(definition)?,
        };
        if matches!(values.front(), Some(Value::Nil)) {
            bail!("failed to restore persisted Lua snippet")
        }
    }
    Ok(())
}

/// Registers only raw bridges. Public schemas remain in core Lua and are guarded
/// by `LuaRuntime` like every other raw facility.
pub(crate) fn register_lua(lua: &Lua, raw: &mlua::Table, store: Store) -> Result<()> {
    let kv = raw.get::<mlua::Table>("kv")?;
    let storage = store.clone();
    kv.set(
        "put",
        lua.create_function(move |lua, values: MultiValue| {
            let mut values = values.into_iter();
            let namespace = expect_string(values.next(), "namespace")?;
            let key = expect_string(values.next(), "key")?;
            let value = values.next().unwrap_or(Value::Nil);
            let options = values.next();
            let (content_type, created_at_s, expires_at_s) = parse_kv_options(options)?;
            let value: JsonValue = match lua.from_value(value) {
                Ok(value) => value,
                Err(error) => {
                    return lua_error(
                        lua,
                        "KV_VALUE_INVALID",
                        format!("value cannot be stored as JSON: {error}"),
                        false,
                    );
                }
            };
            match storage.put_kv(
                &namespace,
                &key,
                &value,
                &content_type,
                created_at_s,
                expires_at_s,
            ) {
                Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
                Err(error) => storage_error(lua, error),
            }
        })?,
    )?;
    let storage = store.clone();
    kv.set(
        "get",
        lua.create_function(move |lua, (namespace, key): (String, String)| {
            match storage.get_kv(&namespace, &key) {
                Ok(Some(value)) => Ok((lua.to_value(&value)?, Value::Nil)),
                Ok(None) => Ok((Value::Nil, Value::Nil)),
                Err(error) => storage_error(lua, error),
            }
        })?,
    )?;
    let storage = store.clone();
    kv.set(
        "delete",
        lua.create_function(move |lua, (namespace, key): (String, String)| {
            match storage.delete_kv(&namespace, &key) {
                Ok(value) => Ok((Value::Boolean(value), Value::Nil)),
                Err(error) => storage_error(lua, error),
            }
        })?,
    )?;
    let storage = store.clone();
    kv.set(
        "keys",
        lua.create_function(
            move |lua, namespace: String| match storage.keys_kv(&namespace) {
                Ok(value) => Ok((lua.to_value(&value)?, Value::Nil)),
                Err(error) => storage_error(lua, error),
            },
        )?,
    )?;
    let storage = store.clone();
    kv.set(
        "len",
        lua.create_function(
            move |lua, namespace: String| match storage.count_kv(&namespace) {
                Ok(value) => Ok((Value::Integer(value), Value::Nil)),
                Err(error) => storage_error(lua, error),
            },
        )?,
    )?;
    let storage = store.clone();
    kv.set(
        "clear",
        lua.create_function(
            move |lua, namespace: String| match storage.clear_kv(&namespace) {
                Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
                Err(error) => storage_error(lua, error),
            },
        )?,
    )?;

    let snippets = raw.get::<mlua::Table>("snippets")?;
    let storage = store.clone();
    snippets.set(
        "save",
        lua.create_function(move |lua, definition: mlua::Table| {
            let path: String = definition
                .get("path")
                .map_err(|_| mlua::Error::runtime("snippet definition requires path"))?;
            let code: String = definition
                .get("code")
                .map_err(|_| mlua::Error::runtime("snippet definition requires code"))?;
            let schema: Option<String> = definition.get("schema_expr").ok();
            let example: Option<String> = definition.get("example").ok();
            let description: Option<String> = definition.get("description").ok();
            match storage.save_snippet(
                &path,
                &code,
                schema.as_deref(),
                example.as_deref(),
                description.as_deref(),
            ) {
                Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
                Err(error) => storage_error(lua, error),
            }
        })?,
    )?;
    let storage = store.clone();
    snippets.set(
        "get",
        lua.create_function(move |lua, path: String| match storage.get_snippet(&path) {
            Ok(Some(value)) => Ok((snippet_to_lua(lua, value)?, Value::Nil)),
            Ok(None) => Ok((Value::Nil, Value::Nil)),
            Err(error) => storage_error(lua, error),
        })?,
    )?;
    let storage = store.clone();
    snippets.set(
        "list",
        lua.create_function(move |lua, ()| match storage.list_snippets() {
            Ok(values) => {
                let table = lua.create_table()?;
                for (index, value) in values.into_iter().enumerate() {
                    table.raw_set(index + 1, snippet_to_lua(lua, value)?)?;
                }
                Ok((Value::Table(table), Value::Nil))
            }
            Err(error) => storage_error(lua, error),
        })?,
    )?;
    snippets.set(
        "delete",
        lua.create_function(move |lua, path: String| match store.delete_snippet(&path) {
            Ok(value) => Ok((Value::Boolean(value), Value::Nil)),
            Err(error) => storage_error(lua, error),
        })?,
    )?;
    Ok(())
}

fn parse_kv_options(value: Option<Value>) -> mlua::Result<(String, Option<i64>, Option<i64>)> {
    let Some(Value::Table(options)) = value else {
        return Ok(("json".to_owned(), None, None));
    };
    Ok((
        options
            .get::<Option<String>>("content_type")?
            .unwrap_or_else(|| "json".to_owned()),
        options.get::<Option<i64>>("created_at_s")?,
        options.get::<Option<i64>>("expires_at_s")?,
    ))
}

fn expect_string(value: Option<Value>, name: &str) -> mlua::Result<String> {
    match value {
        Some(Value::String(value)) => Ok(value.to_string_lossy().to_string()),
        _ => Err(mlua::Error::runtime(format!("KV {name} must be a string"))),
    }
}

fn snippet_to_lua(lua: &Lua, snippet: Snippet) -> mlua::Result<Value> {
    let table = lua.create_table()?;
    table.set("path", snippet.path)?;
    table.set("code", snippet.code)?;
    table.set("schema_expr", snippet.schema_source)?;
    table.set("example", snippet.example_source)?;
    table.set("description", snippet.description)?;
    table.set("created_at_s", snippet.created_at_s)?;
    table.set("updated_at_s", snippet.updated_at_s)?;
    Ok(Value::Table(table))
}

fn storage_error(lua: &Lua, error: anyhow::Error) -> mlua::Result<(Value, Value)> {
    let table = lua.create_table()?;
    table.set("code", "STORAGE_ERROR")?;
    table.set("message", error.to_string())?;
    table.set("recoverable", false)?;
    Ok((Value::Nil, Value::Table(table)))
}
