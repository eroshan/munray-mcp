use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command as ProcessCommand,
    time::Instant,
};

use anyhow::{Result, bail};
use clap::{Parser, Subcommand, ValueEnum};
use mcp_server::{
    mcp::McpServer,
    runtime::{ExecutionMode, LuaRuntime, read_script},
    services, sys_catalog,
};
use rmcp::{ServiceExt, transport::stdio};

const COMMAND_NAME: &str = env!("CARGO_PKG_NAME");

#[derive(Parser)]
#[command(
    name = COMMAND_NAME,
    version,
    about = "Persistent Lua runtime and MCP server"
)]
struct Cli {
    /// Service-pack directory. Defaults to $MUNRAY_MCP_HOME/services, where
    /// MUNRAY_MCP_HOME defaults to $HOME/.local/share/<package name>.
    #[arg(long, global = true, env = "MUNRAY_MCP_SVC_DIR")]
    svc_dir: Option<PathBuf>,
    /// Persist store values, saved Lua snippets, and usage metrics across processes.
    #[arg(long, global = true, env = "MUNRAY_MCP_STORE_PATH")]
    store_path: Option<PathBuf>,
    /// Write owner-only execution JSONL logs.
    #[arg(long, global = true, env = "MUNRAY_MCP_LOGS_DIR")]
    logs_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Execute Lua from stdin or a file (also the default command).
    Run { file: Option<PathBuf> },
    /// Serve MCP JSON-RPC over stdin/stdout.
    Mcp {
        /// Delegate approval of guarded tool calls to the MCP harness when it
        /// does not support Form elicitation. The harness must independently
        /// confirm or restrict every runGuardedLuaScript call.
        #[arg(long)]
        delegate_guarded_approval_to_harness: bool,
    },
    /// Push UTF-8 stdin into an existing MCP session.
    Ingest {
        #[arg(long)]
        server: String,
        #[arg(long)]
        session: String,
        #[arg(long)]
        json: bool,
    },
    /// Report wrapped public function availability and usage metrics.
    Stats {
        #[arg(long)]
        json: bool,
    },
    /// List internal system primitives provided to service packs.
    Sys {
        #[command(subcommand)]
        command: SysCommand,
    },
    /// Manage service packs.
    Svc {
        #[command(subcommand)]
        command: SvcCommand,
    },
}

#[derive(Subcommand)]
enum SysCommand {
    /// List internal system primitives provided to service packs.
    List {
        /// Output representation. JSON is a stable machine-readable catalog.
        #[arg(long, value_enum, default_value_t = SysListFormat::Text)]
        format: SysListFormat,
        /// Maximum line width for text output.
        #[arg(long, default_value_t = 120)]
        width: usize,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum SysListFormat {
    Text,
    Markdown,
    Json,
}

#[derive(Subcommand)]
enum SvcCommand {
    /// Clone a service pack from an HTTPS or Git repository URL.
    Install {
        /// HTTPS or SSH (git@host:path) repository clone URL.
        repository: String,
    },
    /// Create a safe, schema-valid service-pack skeleton.
    Bootstrap {
        /// Lua namespace and directory name (lowercase letters, digits, and underscores).
        #[arg(required_unless_present = "update")]
        name: Option<String>,
        /// Replace files in an existing service directory.
        #[arg(long, conflicts_with = "update")]
        force: bool,
        /// Replace the generated Munray service-pack skill, without changing pack code.
        /// Without a service name, update every service pack in the service directory.
        #[arg(long)]
        update: bool,
    },
    /// List installed service packs.
    List,
    /// Validate all service packs, or one named pack.
    Validate {
        /// Optional service-pack name to validate.
        name: Option<String>,
    },
    /// Run Lua tests for all service packs, or one named pack.
    Test {
        /// Optional service-pack name to test.
        name: Option<String>,
    },
    /// Remove an installed service pack.
    #[command(aliases = ["delete", "remove"])]
    Uninstall {
        /// Directory name of the service pack to remove.
        name: String,
        /// Confirm removal of the service pack directory.
        #[arg(long)]
        force: bool,
    },
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("{error:#}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    let mut cli = Cli::parse();
    cli.svc_dir = resolve_service_dir(cli.svc_dir);
    if let Some(Command::Svc { command }) = &cli.command {
        match command {
            SvcCommand::Install { repository } => {
                install_service(cli.svc_dir.as_deref(), repository)?;
            }
            SvcCommand::Bootstrap {
                name,
                force,
                update,
            } => {
                if *update {
                    update_bootstrap_skill(cli.svc_dir.as_deref(), name.as_deref())?;
                } else {
                    bootstrap_service(
                        cli.svc_dir.as_deref(),
                        name.as_deref()
                            .expect("clap requires a name without --update"),
                        *force,
                    )?;
                }
            }
            SvcCommand::List => list_services(cli.svc_dir.as_deref())?,
            SvcCommand::Validate { name } => {
                let dir = cli
                    .svc_dir
                    .clone()
                    .unwrap_or_else(|| PathBuf::from("services"));
                validate_services(&dir, name.as_deref())?;
            }
            SvcCommand::Test { name } => run_service_tests(cli.svc_dir.clone(), name.as_deref())?,
            SvcCommand::Uninstall { name, force } => {
                uninstall_service(cli.svc_dir.as_deref(), name, *force)?;
            }
        }
        return Ok(());
    }
    cli.store_path = Some(resolve_store_path(cli.store_path)?);
    match cli.command {
        None | Some(Command::Run { file: None }) => {
            execute(None, cli.svc_dir, cli.store_path, cli.logs_dir)
        }
        Some(Command::Run { file: Some(file) }) => {
            execute(Some(file), cli.svc_dir, cli.store_path, cli.logs_dir)
        }
        Some(Command::Mcp {
            delegate_guarded_approval_to_harness,
        }) => {
            let server = McpServer::with_harness_guarded_approval(
                cli.svc_dir,
                cli.store_path,
                cli.logs_dir,
                delegate_guarded_approval_to_harness,
            )
            .map_err(anyhow::Error::msg)?;
            #[cfg(unix)]
            let _ingest = match mcp_server::ipc::start_listener(
                server.clone(),
                &std::process::id().to_string(),
            ) {
                Ok(listener) => Some(listener),
                Err(error) => {
                    eprintln!("warning: ingest IPC unavailable: {error}");
                    None
                }
            };
            server.serve(stdio()).await?.waiting().await?;
            Ok(())
        }
        Some(Command::Ingest {
            server,
            session,
            json,
        }) => run_ingest(&server, &session, json),
        Some(Command::Svc { .. }) => unreachable!("handled before store resolution"),
        Some(Command::Sys {
            command: SysCommand::List { format, width },
        }) => {
            let runtime = LuaRuntime::new(None)?;
            let catalog = sys_catalog::build(runtime.list_sys_primitives()?);
            match format {
                SysListFormat::Text => print!("{}", sys_catalog::render_text(&catalog, width)),
                SysListFormat::Markdown => print!("{}", sys_catalog::render_markdown(&catalog)),
                SysListFormat::Json => println!("{}", serde_json::to_string_pretty(&catalog)?),
            }
            Ok(())
        }
        Some(Command::Stats { json }) => run_stats(cli.svc_dir, cli.store_path, json),
    }
}

const BOOTSTRAP_INIT: &str = include_str!("assets/service-bootstrap/init.lua");
const BOOTSTRAP_RESOURCE: &str = include_str!("assets/service-bootstrap/resource.lua");
const BOOTSTRAP_CAPABILITIES_TEST: &str =
    include_str!("assets/service-bootstrap/capabilities_test.lua");
const BOOTSTRAP_INTEGRATION_TEST: &str =
    include_str!("assets/service-bootstrap/integration_tests.lua");
const BOOTSTRAP_GUARDED_INTEGRATION_TEST: &str =
    include_str!("assets/service-bootstrap/integraion_guarded_tests.lua");
const BOOTSTRAP_EXAMPLE: &str = include_str!("assets/service-bootstrap/service.lua");
const BOOTSTRAP_SKILL: &str = include_str!("assets/service-bootstrap/SKILL.md");

fn install_service(service_dir: Option<&Path>, repository: &str) -> Result<()> {
    let name = service_name_from_repository_url(repository)?;
    let service_dir = require_service_dir(service_dir.map(Path::to_path_buf))?;
    fs::create_dir_all(&service_dir)?;
    // Keep the destination as <services>/<pack>, even when --svc-dir was
    // supplied relatively. Git runs in this directory for stale-cwd safety.
    let service_dir = fs::canonicalize(service_dir)?;
    let pack_dir = service_dir.join(name);
    if pack_dir.exists() {
        bail!("service pack {} already exists", pack_dir.display());
    }

    // Git probes its working directory even when the clone destination is absolute. Run it
    // from the configured service directory so an invocation from a stale/deleted cwd works.
    let status = ProcessCommand::new("git")
        .current_dir(&service_dir)
        .args(["clone", "--", repository])
        .arg(&pack_dir)
        .status()
        .map_err(|error| anyhow::anyhow!("failed to start git: {error}"))?;
    if !status.success() {
        // Git normally removes a failed clone itself. Ensure it cannot be mistaken for an
        // installed pack when it leaves a partial destination behind.
        let _ = fs::remove_dir_all(&pack_dir);
        bail!("git clone failed with status {status}");
    }

    println!("Installed {} in {}", name, pack_dir.display());
    Ok(())
}

fn service_name_from_repository_url(repository: &str) -> Result<&str> {
    let (host, path) = if let Some(remainder) = repository.strip_prefix("https://") {
        remainder
            .split_once('/')
            .ok_or_else(|| anyhow::anyhow!("repository URL must include a repository path"))?
    } else if let Some(remainder) = repository.strip_prefix("git@") {
        remainder
            .split_once(':')
            .ok_or_else(|| anyhow::anyhow!("Git repository URL must include a repository path"))?
    } else {
        bail!("repository URL must use https:// or git@host:path");
    };
    if host.is_empty()
        || host.contains(['@', '?', '#', '\\'])
        || host.bytes().any(|byte| byte.is_ascii_whitespace())
        || path.contains(['?', '#', '\\'])
    {
        bail!("invalid repository URL");
    }

    let directory = path.trim_end_matches('/');
    let name = directory
        .rsplit('/')
        .next()
        .unwrap_or_default()
        .strip_suffix(".git")
        .unwrap_or_else(|| directory.rsplit('/').next().unwrap_or_default());
    let name = name
        .strip_prefix(&format!("{COMMAND_NAME}-"))
        .unwrap_or(name);
    if !is_service_directory_name(name) {
        bail!("repository name {name:?} cannot be used as a service directory");
    }
    Ok(name)
}

fn is_service_directory_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('.')
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

fn bootstrap_service(service_dir: Option<&Path>, name: &str, force: bool) -> Result<()> {
    if !is_service_name(name) {
        bail!(
            "invalid service name {name:?}: use lowercase ASCII letters, digits, and underscores; the first character must be a letter"
        );
    }
    let service_dir = require_service_dir(service_dir.map(Path::to_path_buf))?;
    let pack_dir = service_dir.join(name);
    if pack_dir.exists() && !pack_dir.is_dir() {
        bail!("service path {} is not a directory", pack_dir.display());
    }
    if pack_dir.exists() && !force {
        bail!(
            "service pack {} already exists; choose another name or pass --force to replace bootstrap files",
            pack_dir.display()
        );
    }

    let files = [
        ("src/init.lua", BOOTSTRAP_INIT),
        ("src/resource.lua", BOOTSTRAP_RESOURCE),
        ("tests/capabilities_test.lua", BOOTSTRAP_CAPABILITIES_TEST),
        ("tests/integration_tests.lua", BOOTSTRAP_INTEGRATION_TEST),
        (
            "tests/integraion_guarded_tests.lua",
            BOOTSTRAP_GUARDED_INTEGRATION_TEST,
        ),
        (&format!("examples/{name}.lua"), BOOTSTRAP_EXAMPLE),
        (
            ".agents/skills/munray-service-pack/SKILL.md",
            BOOTSTRAP_SKILL,
        ),
    ];
    for (relative, template) in files {
        let path = pack_dir.join(relative);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, template.replace("{{SERVICE}}", name))?;
        println!("Created {}", path.display());
    }
    println!("\nNext steps:");
    println!("  1. Replace <...> placeholders and the NOT_IMPLEMENTED starter operation.");
    println!(
        "  2. {} validate --svc-dir {}",
        COMMAND_NAME,
        service_dir.display()
    );
    println!(
        "  3. {} test --svc-dir {}",
        COMMAND_NAME,
        service_dir.display()
    );
    Ok(())
}

fn update_bootstrap_skill(service_dir: Option<&Path>, name: Option<&str>) -> Result<()> {
    let service_dir = require_service_dir(service_dir.map(Path::to_path_buf))?;
    let pack_dirs = if let Some(name) = name {
        if !is_service_directory_name(name) {
            bail!("invalid service directory name {name:?}");
        }
        vec![service_dir.join(name)]
    } else {
        if !service_dir.exists() {
            println!("No service packs found in {}", service_dir.display());
            return Ok(());
        }
        if !service_dir.is_dir() {
            bail!("service path {} is not a directory", service_dir.display());
        }
        let mut packs = fs::read_dir(&service_dir)?
            .filter_map(Result::ok)
            .filter(|entry| {
                !entry.file_name().to_string_lossy().starts_with('.')
                    && entry.file_type().is_ok_and(|kind| kind.is_dir())
                    && entry.path().join("src").is_dir()
            })
            .map(|entry| entry.path())
            .collect::<Vec<_>>();
        packs.sort();
        packs
    };

    if pack_dirs.is_empty() {
        println!("No service packs found in {}", service_dir.display());
        return Ok(());
    }
    for pack_dir in pack_dirs {
        if !pack_dir.is_dir() || !pack_dir.join("src").is_dir() {
            bail!("service pack {} does not exist", pack_dir.display());
        }
        let path = pack_dir.join(".agents/skills/munray-service-pack/SKILL.md");
        fs::create_dir_all(path.parent().expect("skill path has a parent"))?;
        fs::write(&path, BOOTSTRAP_SKILL)?;
        println!("Updated {}", path.display());
    }
    Ok(())
}

fn list_services(service_dir: Option<&Path>) -> Result<()> {
    let service_dir = require_service_dir(service_dir.map(Path::to_path_buf))?;
    if !service_dir.exists() {
        println!("No service packs found in {}", service_dir.display());
        return Ok(());
    }
    if !service_dir.is_dir() {
        bail!("service path {} is not a directory", service_dir.display());
    }

    let mut packs = Vec::new();
    for entry in fs::read_dir(&service_dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.')
            || !entry.file_type()?.is_dir()
            || !entry.path().join("src").is_dir()
        {
            continue;
        }
        packs.push(name);
    }
    packs.sort();
    if packs.is_empty() {
        println!("No service packs found in {}", service_dir.display());
    } else {
        println!("Service packs in {}:", service_dir.display());
        for pack in packs {
            println!("  {pack}");
        }
    }
    Ok(())
}

fn uninstall_service(service_dir: Option<&Path>, name: &str, force: bool) -> Result<()> {
    if !is_service_directory_name(name) {
        bail!("invalid service directory name {name:?}");
    }
    let service_dir = require_service_dir(service_dir.map(Path::to_path_buf))?;
    let pack_dir = service_dir.join(name);
    if !pack_dir.exists() {
        bail!("service pack {} does not exist", pack_dir.display());
    }
    if !pack_dir.is_dir() {
        bail!("service path {} is not a directory", pack_dir.display());
    }
    if !force {
        bail!(
            "refusing to remove service pack {}; pass --force to confirm",
            pack_dir.display()
        );
    }
    fs::remove_dir_all(&pack_dir)?;
    println!("Removed {}", pack_dir.display());
    Ok(())
}

fn is_service_name(name: &str) -> bool {
    let mut bytes = name.bytes();
    matches!(bytes.next(), Some(b'a'..=b'z'))
        && bytes.all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn run_ingest(server: &str, session: &str, json_mode: bool) -> Result<()> {
    if server.trim().is_empty() {
        bail!("--server is required")
    }
    if session.trim().is_empty() {
        bail!("--session is required")
    }
    let mut payload = Vec::new();
    std::io::stdin()
        .take((mcp_server::ipc::MAX_INGEST_BYTES + 1) as u64)
        .read_to_end(&mut payload)?;
    if payload.len() > mcp_server::ipc::MAX_INGEST_BYTES {
        bail!("stdin exceeds {} bytes", mcp_server::ipc::MAX_INGEST_BYTES)
    }
    std::str::from_utf8(&payload).map_err(|_| anyhow::anyhow!("stdin is not valid UTF-8"))?;
    #[cfg(unix)]
    let response =
        mcp_server::ipc::send_text(server, session, &payload).map_err(anyhow::Error::msg)?;
    #[cfg(not(unix))]
    bail!("ingest IPC is not supported on this platform");
    if !response.ok {
        let error = response.error.unwrap_or(mcp_server::ipc::IngestError {
            code: "INGEST_WRITE_FAILED".into(),
            message: "ingest failed".into(),
            recoverable: false,
        });
        if json_mode {
            println!(
                "{}",
                serde_json::to_string(&serde_json::json!({"ok":false,"error":error}))?
            );
        }
        bail!(error.message)
    }
    let token = response.token.expect("successful ingest has token");
    if json_mode {
        println!(
            "{}",
            serde_json::to_string(
                &serde_json::json!({"ok":true,"token":token,"bytes":response.bytes,"lua_hint":format!("local text, err = ingest.get({token:?})")})
            )?
        );
    } else {
        println!(
            "Stored {} bytes as {}",
            response.bytes.unwrap_or(payload.len()),
            token
        );
        println!("Lua: local text, err = ingest.get({token:?})");
    }
    Ok(())
}

fn execute(
    file: Option<PathBuf>,
    service_dir: Option<PathBuf>,
    store_path: Option<PathBuf>,
    logs_dir: Option<PathBuf>,
) -> Result<()> {
    let code = read_script(file.as_deref())?;
    let runtime = LuaRuntime::new_persistent(
        service_dir.as_deref(),
        store_path
            .as_deref()
            .expect("store path is resolved before execution"),
    )?;
    let started = std::time::Instant::now();
    let execution = runtime.execute(
        &code,
        ExecutionMode::Guarded,
        file.as_ref().map_or("<stdin>", |_| "<file>"),
    );
    let (output, result, error) = match execution {
        Ok(execution) => (execution.output, execution.result, None),
        Err(error) => (
            runtime.captured_output(),
            serde_json::Value::Null,
            Some(format!("{error:#}")),
        ),
    };
    if let Some(logs_dir) = logs_dir {
        mcp_server::logging::Logger::new(&logs_dir)?.log(mcp_server::logging::ExecutionEntry {
            timestamp_ms: mcp_server::logging::now_ms(),
            session_id: "cli".into(),
            mode: "guarded".into(),
            code,
            output: output.clone(),
            result: result.clone(),
            error: error.clone(),
            duration_ms: started.elapsed().as_millis(),
        })?;
    }
    print!("{output}");
    if let Some(error) = error {
        bail!(error);
    }
    if !result.is_null() {
        println!("{}", serde_json::to_string_pretty(&result)?);
    }
    Ok(())
}

fn run_stats(
    service_dir: Option<PathBuf>,
    store_path: Option<PathBuf>,
    json_mode: bool,
) -> Result<()> {
    let store_path = store_path.expect("store path is resolved before stats");
    let stats = mcp_server::stats::collect_report(service_dir.as_deref(), &store_path)?;
    if json_mode {
        println!("{}", serde_json::to_string_pretty(&stats)?);
    } else {
        print!("{}", mcp_server::stats::render_text(&stats));
    }
    Ok(())
}

fn require_service_dir(path: Option<PathBuf>) -> Result<PathBuf> {
    path.ok_or_else(|| {
        anyhow::anyhow!(
            "service directory required: pass --svc-dir, set MUNRAY_MCP_SVC_DIR, or set MUNRAY_MCP_HOME/HOME"
        )
    })
}

fn resolve_service_dir(path: Option<PathBuf>) -> Option<PathBuf> {
    path.or_else(|| data_home().map(|home| home.join("services")))
}

fn resolve_store_path(path: Option<PathBuf>) -> Result<PathBuf> {
    let path = path
        .or_else(|| data_home().map(|home| home.join("store.db")))
        .ok_or_else(|| anyhow::anyhow!("store path required: pass --store-path or set HOME"))?;
    if path.is_absolute() {
        Ok(path)
    } else {
        Ok(std::env::current_dir()?.join(path))
    }
}

fn data_home() -> Option<PathBuf> {
    nonempty_env_path("MUNRAY_MCP_HOME").or_else(|| {
        nonempty_env_path("HOME").map(|home| {
            home.join(".local")
                .join("share")
                .join(env!("CARGO_PKG_NAME"))
        })
    })
}

fn nonempty_env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn is_skipped_test(result: &serde_json::Value) -> bool {
    result
        .get("__munray_test_status")
        .and_then(serde_json::Value::as_str)
        == Some("SKIPPED")
}

fn validate_services(dir: &Path, service_name: Option<&str>) -> Result<()> {
    validate_service_name(dir, service_name)?;
    services::validate(dir, service_name)?;
    Ok(())
}

fn validate_service_name(service_dir: &Path, service_name: Option<&str>) -> Result<()> {
    let Some(name) = service_name else {
        return Ok(());
    };
    if !is_service_directory_name(name) {
        bail!("invalid service directory name {name:?}");
    }
    let pack = service_dir.join(name);
    if !pack.is_dir() || !pack.join("src").is_dir() {
        bail!(
            "service pack {name:?} does not exist in {}",
            service_dir.display()
        );
    }
    Ok(())
}

fn run_service_tests(service_dir: Option<PathBuf>, service_name: Option<&str>) -> Result<()> {
    let dir = require_service_dir(service_dir)?;
    validate_service_name(&dir, service_name)?;
    let tests_dir = service_name.map_or_else(|| dir.clone(), |name| dir.join(name));
    let mut failures = 0;
    for entry in walkdir::WalkDir::new(&tests_dir)
        .follow_links(true)
        .into_iter()
        .filter_map(Result::ok)
    {
        let path = entry.path();
        if !entry.file_type().is_file()
            || path.extension().is_none_or(|ext| ext != "lua")
            || !path.components().any(|part| part.as_os_str() == "tests")
        {
            continue;
        }
        let code = std::fs::read_to_string(path)?;
        println!("RUNNING {}", path.display());
        std::io::stdout().flush()?;
        let started = Instant::now();
        let guarded_integration = path
            .file_name()
            .is_some_and(|name| name == "integraion_guarded_tests.lua");
        let mode = if guarded_integration
            && std::env::var("MUNRAY_RUN_GUARDED").ok().as_deref() == Some("1")
        {
            ExecutionMode::Guarded
        } else {
            ExecutionMode::ReadOnly
        };
        let runtime = match service_name {
            Some(name) => LuaRuntime::new_with_service_for_tests(&dir, name)?,
            None => LuaRuntime::new_with_options(Some(&dir), true)?,
        };
        match runtime.execute(&code, mode, &path.to_string_lossy()) {
            Ok(execution) if is_skipped_test(&execution.result) => {
                let reason = execution
                    .result
                    .get("reason")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("test requested skip");
                println!(
                    "SKIPPED {} ({:.1}s): {reason}",
                    path.display(),
                    started.elapsed().as_secs_f64()
                );
            }
            Ok(_) => println!(
                "PASS {} ({:.1}s)",
                path.display(),
                started.elapsed().as_secs_f64()
            ),
            Err(error) => {
                failures += 1;
                eprintln!(
                    "FAIL {} ({:.1}s): {error:#}",
                    path.display(),
                    started.elapsed().as_secs_f64()
                );
            }
        }
    }
    if failures > 0 {
        bail!("{failures} test file(s) failed")
    }
    Ok(())
}
