use std::fs;
use std::time::{Duration, Instant};

use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

fn runtime_with_shell() -> (tempfile::TempDir, LuaRuntime) {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        "demo = { __allowed_cli_commands = {'sh'} }",
    )
    .unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    (services, runtime)
}

#[test]
fn synchronous_cli_honors_timeout_option() {
    let (_services, runtime) = runtime_with_shell();
    let execution = runtime
        .execute(
            "local value, err = _raw.cli.text('sh', {'-c', 'while :; do :; done'}, {timeout=0.02}); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(execution.result, "TIMEOUT");
}

#[test]
fn cli_blob_honors_timeout_option() {
    let (_services, runtime) = runtime_with_shell();
    let execution = runtime
        .execute(
            "local value, err = _raw.blob.from_cli('sh', {'-c', 'while :; do :; done'}, {timeout=0.02}); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(execution.result, "TIMEOUT");
}

#[test]
fn cli_inherits_the_active_lua_execution_deadline() {
    let (_services, runtime) = runtime_with_shell();
    let started = Instant::now();
    let execution = runtime
        .execute_with_timeout(
            "local value, err = _raw.cli.text('sh', {'-c', 'while :; do :; done'}, {timeout=5}); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
            Some(Duration::from_millis(30)),
        )
        .unwrap();
    assert_eq!(execution.result, "TIMEOUT");
    assert!(started.elapsed() < Duration::from_millis(500));
}
