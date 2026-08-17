use std::{io::Read, path::PathBuf};

use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use mcp_server::{
    mcp::McpServer,
    runtime::{ExecutionMode, LuaRuntime, read_script},
    services,
};
use rmcp::{ServiceExt, transport::stdio};

#[derive(Parser)]
#[command(
    name = env!("CARGO_PKG_NAME"),
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
    Mcp,
    /// Validate that all service-pack Lua modules load.
    Validate,
    /// Push UTF-8 stdin into an existing MCP session.
    Ingest {
        #[arg(long)]
        server: String,
        #[arg(long)]
        session: String,
        #[arg(long)]
        json: bool,
    },
    /// Run Lua tests found under service-pack tests directories.
    Test,
    /// List internal system primitives provided to service packs.
    ListSys,
    /// Report wrapped public function availability and usage metrics.
    Stats {
        #[arg(long)]
        json: bool,
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
    // Validation has no persistence requirement: its runtime uses a temporary
    // store, and base-only validation must work without HOME.
    if matches!(cli.command, Some(Command::Validate)) {
        let dir = cli.svc_dir.unwrap_or_else(|| PathBuf::from("services"));
        services::validate(&dir)?;
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
        Some(Command::Mcp) => {
            let server = McpServer::with_options(cli.svc_dir, cli.store_path, cli.logs_dir)
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
        Some(Command::Validate) => unreachable!("handled before store resolution"),
        Some(Command::Test) => run_service_tests(cli.svc_dir),
        Some(Command::ListSys) => {
            let runtime = LuaRuntime::new(None)?;
            println!("Available sys.* primitives:");
            for (namespace, functions) in runtime.list_sys_primitives()? {
                println!("\n{namespace}:");
                for function in functions {
                    println!("  {namespace}.{function}");
                }
            }
            Ok(())
        }
        Some(Command::Stats { json }) => run_stats(cli.svc_dir, cli.store_path, json),
    }
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
    )?;
    if let Some(logs_dir) = logs_dir {
        mcp_server::logging::Logger::new(&logs_dir)?.log(mcp_server::logging::ExecutionEntry {
            timestamp_ms: mcp_server::logging::now_ms(),
            session_id: "cli".into(),
            mode: "guarded".into(),
            code,
            output: execution.output.clone(),
            result: execution.result.clone(),
            error: None,
            duration_ms: started.elapsed().as_millis(),
        })?;
    }
    print!("{}", execution.output);
    if !execution.result.is_null() {
        println!("{}", serde_json::to_string_pretty(&execution.result)?);
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

fn run_service_tests(service_dir: Option<PathBuf>) -> Result<()> {
    let dir = require_service_dir(service_dir)?;
    let mut failures = 0;
    for entry in walkdir::WalkDir::new(&dir)
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
        let runtime = LuaRuntime::new_with_options(Some(&dir), true)?;
        match runtime.execute(&code, ExecutionMode::ReadOnly, &path.to_string_lossy()) {
            Ok(_) => println!("PASS {}", path.display()),
            Err(error) => {
                failures += 1;
                eprintln!("FAIL {}: {error:#}", path.display());
            }
        }
    }
    if failures > 0 {
        bail!("{failures} test file(s) failed")
    }
    Ok(())
}
