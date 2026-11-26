use super::{client, config::Connection};
use crate::runtime::{LuaRuntime, json_value_to_lua, lua_error, lua_value_to_json_with_limit};
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use mlua::{AnyUserData, Lua, Table, UserData, Value};
use rmcp::model::{JsonObject, Tool};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt::Write as _,
    fs::{self, File},
    io::{Read, Write},
    path::Path,
    sync::{Arc, OnceLock, mpsc},
    time::{Duration, Instant},
};
use tokio::{runtime::Runtime, time::timeout};
use uuid::Uuid;

pub(crate) const MANIFEST: &str = "mcp-catalog.json";
const POLICY: &str = "config.lua";
const INIT: &str = include_str!("../assets/mcp-client/init.lua");
const SKILL: &str = include_str!("../assets/service-bootstrap/SKILL.md");
const MAX_CATALOG_BYTES: usize = 32 * 1024 * 1024;
const MAX_POLICY_BYTES: usize = 4 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
struct Catalog {
    version: u32,
    integration: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    connection: Option<Connection>,
    tools: Vec<Tool>,
    aliases: BTreeMap<String, String>,
}

pub async fn bootstrap(
    services: &Path,
    name: &str,
    connection: Connection,
    store_path: Option<&Path>,
    budget: Duration,
) -> Result<()> {
    check_name(name)?;
    let directory = services.join(name);
    ensure!(
        !directory.exists(),
        "service pack {} already exists",
        directory.display()
    );
    LuaRuntime::with_trusted_bootstrap(store_path, |lua| {
        ensure!(
            lua.globals().raw_get::<Value>(name)?.is_nil(),
            "MCP pack namespace {name:?} conflicts with a built-in Lua global"
        );
        crate::services::load(lua, services)
            .context("load installed services to check MCP namespace")?;
        ensure!(
            lua.globals().raw_get::<Value>(name)?.is_nil(),
            "MCP pack namespace {name:?} is already used by an installed service"
        );
        Ok(())
    })?;
    connection.validate()?;
    let integration = Uuid::new_v4();
    let tools = scan(&connection, integration, budget).await?;
    let mut catalog = Catalog {
        version: 2,
        integration,
        connection: None,
        tools,
        aliases: BTreeMap::new(),
    };
    catalog.update_aliases();

    fs::create_dir_all(services)?;
    let staging = tempfile::Builder::new()
        .prefix(".mcp-bootstrap-")
        .tempdir_in(services)?;
    let src = staging.path().join("src");
    fs::create_dir(&src)?;
    fs::write(src.join("init.lua"), INIT)?;
    let skill_dir = staging.path().join(".agents/skills/munray-service-pack");
    fs::create_dir_all(&skill_dir)?;
    fs::write(
        skill_dir.join("SKILL.md"),
        SKILL.replace("{{SERVICE}}", name),
    )?;
    let policy = catalog.config(&connection)?;
    ensure!(
        policy.len() <= MAX_POLICY_BYTES,
        "generated MCP config.lua exceeds 4 MiB"
    );
    fs::write(staging.path().join(POLICY), policy)?;
    catalog.save(staging.path())?;
    ensure!(
        !directory.exists(),
        "service pack {} already exists",
        directory.display()
    );
    fs::rename(staging.path(), &directory).context("install generated MCP service pack")?;
    println!(
        "Created {} with {} MCP tools",
        directory.display(),
        catalog.tools.len()
    );
    Ok(())
}

pub async fn refresh(
    services: &Path,
    name: &str,
    store_path: Option<&Path>,
    budget: Duration,
) -> Result<()> {
    check_name(name)?;
    let directory = services.join(name);
    ensure!(
        directory.join(MANIFEST).is_file(),
        "{name:?} is not a generated MCP service pack"
    );
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(directory.join(".mcp-refresh.lock"))?;
    FileExt::try_lock_exclusive(&lock).context("another MCP catalog refresh is in progress")?;
    let mut catalog = Catalog::read(&directory)?;
    let connection = if let Some(connection) = &catalog.connection {
        connection.clone()
    } else {
        LuaRuntime::with_trusted_bootstrap(store_path, |lua| {
            parse_connection(read_config(lua, &directory)?.raw_get("connection")?)
        })?
    };
    let tools = scan(&connection, catalog.integration, budget).await?;
    let old = catalog
        .tools
        .iter()
        .map(|tool| (tool.name.to_string(), tool))
        .collect::<BTreeMap<_, _>>();
    let new = tools
        .iter()
        .map(|tool| (tool.name.to_string(), tool))
        .collect::<BTreeMap<_, _>>();
    let mut changes = Vec::new();
    let policy_location = if catalog.version == 2 {
        "config.lua under tools"
    } else {
        "config.lua"
    };
    for (name, tool) in &new {
        match old.get(name) {
            None => changes.push(format!(
                "Added {name:?}; enable it in {policy_location} with {} = {{ enabled = true, guarded = true }},",
                lua_key(name)
            )),
            Some(previous) if previous != tool => changes.push(format!("Updated {name:?}")),
            _ => {}
        }
    }
    for name in old.keys() {
        if !new.contains_key(name) {
            changes.push(format!("Removed {name:?}"));
        }
    }
    catalog.tools = tools;
    catalog.update_aliases();
    catalog.save(&directory)?;
    for change in changes {
        println!("{change}");
    }
    println!(
        "Refreshed {} ({} MCP tools)",
        directory.display(),
        catalog.tools.len()
    );
    Ok(())
}

async fn scan(connection: &Connection, integration: Uuid, budget: Duration) -> Result<Vec<Tool>> {
    timeout(budget, client::list(connection, integration))
        .await
        .context("MCP catalog scan timed out")?
}

impl Catalog {
    fn read(directory: &Path) -> Result<Self> {
        let file = directory.join(MANIFEST);
        let mut data = Vec::new();
        File::open(&file)
            .with_context(|| format!("open remote MCP catalog {}", file.display()))?
            .take((MAX_CATALOG_BYTES + 1) as u64)
            .read_to_end(&mut data)?;
        ensure!(
            data.len() <= MAX_CATALOG_BYTES,
            "remote MCP catalog exceeds 32 MiB"
        );
        let catalog: Self = serde_json::from_slice(&data).context("invalid remote MCP catalog")?;
        ensure!(
            matches!(
                (catalog.version, &catalog.connection),
                (1, Some(_)) | (2, None)
            ),
            "unsupported remote MCP catalog version"
        );
        Ok(catalog)
    }

    fn save(&self, directory: &Path) -> Result<()> {
        let data = serde_json::to_vec_pretty(self)?;
        ensure!(
            data.len() <= MAX_CATALOG_BYTES,
            "remote MCP catalog exceeds 32 MiB"
        );
        let mut file = tempfile::NamedTempFile::new_in(directory)?;
        file.write_all(&data)?;
        file.write_all(b"\n")?;
        file.as_file().sync_all()?;
        file.persist(directory.join(MANIFEST))
            .map_err(|error| error.error)?;
        Ok(())
    }

    fn update_aliases(&mut self) {
        let mut used = self.aliases.values().cloned().collect::<HashSet<_>>();
        let mut next_suffix = HashMap::new();
        for tool in &self.tools {
            if self.aliases.contains_key(tool.name.as_ref()) {
                continue;
            }
            let base = lua_alias(&tool.name);
            let alias = if used.insert(base.clone()) {
                base
            } else {
                let next = next_suffix.entry(base.clone()).or_insert(2);
                loop {
                    let alias = format!("{base}_{next}");
                    *next += 1;
                    if used.insert(alias.clone()) {
                        break alias;
                    }
                }
            };
            self.aliases.insert(tool.name.to_string(), alias);
        }
    }

    fn config(&self, connection: &Connection) -> Result<String> {
        let mut out = String::from("return {\n    connection = ");
        write_lua_config(&mut out, &serde_json::to_value(connection)?, 1)?;
        out.push_str(",\n    tools = {\n");
        for tool in &self.tools {
            writeln!(
                out,
                "        {} = {{ enabled = true, guarded = true }},",
                lua_key(&tool.name)
            )?;
        }
        out.push_str("    },\n}\n");
        Ok(out)
    }
}

fn lua_string(text: &str) -> String {
    let mut out = String::from("\"");
    for char in text.chars() {
        match char {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            char if char.is_ascii_control() => {
                write!(out, "\\{:03}", char as u32).expect("write to String");
            }
            char => out.push(char),
        }
    }
    out.push('"');
    out
}

const LUA_KEYWORDS: &[&str] = &[
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
];

fn lua_key(key: &str) -> String {
    let mut bytes = key.bytes();
    if matches!(bytes.next(), Some(b'a'..=b'z' | b'A'..=b'Z' | b'_'))
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        && !LUA_KEYWORDS.contains(&key)
    {
        key.to_owned()
    } else {
        format!("[{}]", lua_string(key))
    }
}

fn check_name(name: &str) -> Result<()> {
    let mut bytes = name.bytes();
    ensure!(
        matches!(bytes.next(), Some(b'a'..=b'z'))
            && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
            && !LUA_KEYWORDS.contains(&name),
        "invalid Lua service name {name:?}"
    );
    Ok(())
}

fn lua_alias(name: &str) -> String {
    let base = name
        .chars()
        .map(|char| {
            if char.is_ascii_alphanumeric() {
                char
            } else {
                '_'
            }
        })
        .collect::<String>();
    if base.starts_with("__")
        || !base.starts_with(|char: char| char.is_ascii_alphabetic() || char == '_')
        || LUA_KEYWORDS.contains(&base.as_str())
    {
        format!("tool_{base}")
    } else {
        base
    }
}

fn write_lua_config(out: &mut String, value: &serde_json::Value, depth: usize) -> Result<()> {
    match value {
        serde_json::Value::Object(fields) => {
            let mut fields = fields
                .iter()
                .filter(|(_, value)| !value.is_null())
                .peekable();
            if fields.peek().is_none() {
                out.push_str("{}");
                return Ok(());
            }
            out.push_str("{\n");
            let indent = "    ".repeat(depth);
            for (key, value) in fields {
                write!(out, "{indent}    {} = ", lua_key(key))?;
                write_lua_config(out, value, depth + 1)?;
                out.push_str(",\n");
            }
            write!(out, "{indent}}}")?;
        }
        serde_json::Value::String(value) => out.push_str(&lua_string(value)),
        serde_json::Value::Bool(value) => write!(out, "{value}")?,
        _ => anyhow::bail!("unexpected MCP connection setting"),
    }
    Ok(())
}

fn read_config(lua: &Lua, directory: &Path) -> Result<Table> {
    let file = directory.join(POLICY);
    let mut config = Vec::new();
    File::open(&file)
        .with_context(|| format!("open MCP config {}", file.display()))?
        .take((MAX_POLICY_BYTES + 1) as u64)
        .read_to_end(&mut config)?;
    ensure!(
        config.len() <= MAX_POLICY_BYTES,
        "MCP config.lua exceeds 4 MiB"
    );
    lua.load(&config)
        .set_name(file.to_string_lossy())
        .eval()
        .context("evaluate MCP config.lua")
}

fn parse_connection(value: Value) -> Result<Connection> {
    let connection: Connection = serde_json::from_value(lua_value_to_json_with_limit(value, 1024)?)
        .context("invalid MCP connection settings")?;
    connection.validate()?;
    Ok(connection)
}

struct AuthRef {
    connection: Arc<Connection>,
    integration: Uuid,
}

impl UserData for AuthRef {}

pub(crate) fn register(lua: &Lua, raw: &Table) -> mlua::Result<()> {
    let api = lua.create_table()?;
    api.set(
        "config",
        lua.create_function(|lua, directory: String| {
            match read_config(lua, Path::new(&directory)) {
                Ok(config) => Ok((Value::Table(config), Value::Nil)),
                Err(error) => lua_error(lua, "MCP_CONFIG_ERROR", format!("{error:#}"), false),
            }
        })?,
    )?;
    api.set(
        "auth",
        lua.create_function(|lua, (connection, integration): (Value, Option<String>)| {
            let parsed = parse_connection(connection).and_then(|connection| {
                let integration = integration
                    .as_deref()
                    .map(Uuid::parse_str)
                    .transpose()?
                    .unwrap_or(Uuid::nil());
                Ok(AuthRef {
                    connection: Arc::new(connection),
                    integration,
                })
            });
            match parsed {
                Ok(auth) => Ok((Value::UserData(lua.create_userdata(auth)?), Value::Nil)),
                Err(error) => lua_error(lua, "MCP_CONFIG_ERROR", format!("{error:#}"), false),
            }
        })?,
    )?;
    api.set(
        "tool_call",
        lua.create_function(|lua, (auth, name, args): (AnyUserData, String, Value)| {
            let auth = auth.borrow::<AuthRef>()?;
            invoke(
                lua,
                Arc::clone(&auth.connection),
                auth.integration,
                &name,
                args,
            )
        })?,
    )?;
    api.set(
        "catalog",
        lua.create_function(|lua, directory: String| {
            match lua_catalog(lua, Path::new(&directory)) {
                Ok(catalog) => Ok((Value::Table(catalog), Value::Nil)),
                Err(error) => lua_error(lua, "MCP_PACK_ERROR", format!("{error:#}"), false),
            }
        })?,
    )?;
    api.set(
        "load",
        lua.create_function(|lua, (name, directory): (String, String)| {
            match load_legacy(lua, &name, &directory) {
                Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
                Err(error) => lua_error(lua, "MCP_PACK_ERROR", format!("{error:#}"), false),
            }
        })?,
    )?;
    raw.set("mcp", api)
}

fn load_legacy(lua: &Lua, name: &str, directory: &str) -> Result<()> {
    check_name(name)?;
    let path = Path::new(directory);
    let catalog = Catalog::read(path)?;
    let connection = catalog
        .connection
        .context("MCP pack uses config.lua connection settings")?;
    let config = lua.create_table()?;
    config.set(
        "connection",
        json_value_to_lua(lua, &serde_json::to_value(connection)?)?,
    )?;
    config.set("tools", read_config(lua, path)?)?;
    lua.load(INIT)
        .set_name("legacy MCP pack")
        .call::<()>((name, directory, config))?;
    Ok(())
}

fn lua_catalog(lua: &Lua, directory: &Path) -> Result<Table> {
    let catalog = Catalog::read(directory)?;
    let tools = lua.create_table()?;
    let mut aliases = HashSet::new();
    for tool in catalog.tools {
        let alias = catalog
            .aliases
            .get(tool.name.as_ref())
            .context("MCP tool alias missing")?;
        ensure!(
            lua_alias(alias) == *alias && aliases.insert(alias),
            "invalid or duplicate MCP tool alias {alias:?}"
        );
        let entry = lua.create_table()?;
        entry.set("lua_name", alias.as_str())?;
        entry.set(
            "description",
            tool.description
                .as_deref()
                .or(tool.title.as_deref())
                .unwrap_or("External MCP tool"),
        )?;
        entry.set(
            "input_schema",
            json_value_to_lua(lua, &json!(tool.input_schema))?,
        )?;
        if let Some(output) = tool.output_schema {
            entry.set("output_schema", json_value_to_lua(lua, &json!(output))?)?;
        }
        tools.raw_set(tool.name.as_ref(), entry)?;
    }
    let result = lua.create_table()?;
    result.set("tools", tools)?;
    result.set("integration", catalog.integration.to_string())?;
    Ok(result)
}

fn invoke(
    lua: &Lua,
    connection: Arc<Connection>,
    integration: Uuid,
    tool: &str,
    args: Value,
) -> mlua::Result<(Value, Value)> {
    let args = match args {
        Value::Nil => JsonObject::new(),
        args => match lua_value_to_json_with_limit(args, 1_000_000) {
            Ok(serde_json::Value::Object(args)) => args,
            _ => {
                return lua_error(
                    lua,
                    "MCP_ARGUMENTS",
                    "MCP arguments must be a JSON object".to_owned(),
                    false,
                );
            }
        },
    };
    let Some(budget) = crate::deadline::effective(Duration::from_secs(
        if crate::deadline::snapshot().is_some() {
            600
        } else {
            60
        },
    )) else {
        return lua_error(lua, "MCP_TIMEOUT", "MCP call timed out".to_owned(), true);
    };
    let runtime = match client_runtime() {
        Ok(runtime) => runtime,
        Err(error) => return lua_error(lua, "MCP_CLIENT_ERROR", error.to_string(), false),
    };
    let (send, receive) = mpsc::sync_channel(1);
    let tool = tool.to_owned();
    let deadline = Instant::now() + budget;
    let operation = runtime.spawn(async move {
        let result = tokio::time::timeout_at(
            deadline.into(),
            client::call(&connection, integration, tool, args),
        )
        .await;
        let _ = send.send(result);
    });
    let response = match receive.recv_timeout(budget) {
        Ok(Ok(Ok(response))) => response,
        Ok(Ok(Err(error))) => {
            return lua_error(lua, "MCP_CALL_FAILED", format!("{error:#}"), false);
        }
        Ok(Err(_)) | Err(mpsc::RecvTimeoutError::Timeout) => {
            operation.abort();
            return lua_error(
                lua,
                "MCP_TIMEOUT",
                "MCP call exceeded its deadline; its remote outcome may be unknown".to_owned(),
                false,
            );
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            return lua_error(
                lua,
                "MCP_CLIENT_ERROR",
                "MCP client worker stopped".to_owned(),
                true,
            );
        }
    };
    let is_error = response.is_error == Some(true);
    let result = serde_json::to_value(response).map_err(mlua::Error::external)?;
    let value = json_value_to_lua(lua, &result)?;
    if is_error {
        let (_, error) = lua_error(
            lua,
            "MCP_TOOL_ERROR",
            "external MCP tool reported an error".to_owned(),
            false,
        )?;
        if let Value::Table(error) = &error {
            error.get::<Table>("context")?.set("result", value)?;
        }
        return Ok((Value::Nil, error));
    }
    Ok((value, Value::Nil))
}

fn client_runtime() -> Result<&'static Runtime> {
    static RUNTIME: OnceLock<std::result::Result<Runtime, std::io::Error>> = OnceLock::new();
    RUNTIME
        .get_or_init(|| {
            tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(2)
                .thread_name("munray-mcp-client")
                .build()
        })
        .as_ref()
        .map_err(|error| anyhow::anyhow!("start MCP client runtime: {error}"))
}
