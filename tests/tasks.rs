use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn async_cli_json_can_be_waited_for() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        "demo = { __allowed_cli_commands = {'sh'} }",
    )
    .unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let result = runtime.execute(
        r#"local id, err = sys.cli.start_json('sh', {'-c', [[printf '{"ok":true}']]}); if err then error(err.message) end; local value, wait_err = async_task.wait(id, 5000); if wait_err then error(wait_err.message) end; return value.ok"#,
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}

#[test]
fn cancel_schema_declares_guarded_policy() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local schema = schema('async_task'); for _, fn in ipairs(schema.functions) do if fn.name == 'cancel' then return fn.guarded end end",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, true);
}

#[test]
fn cancelling_a_task_requires_guarded_execution() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local value, err = async_task.cancel('missing'); return {value == nil, err.code}",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(
        result.result,
        serde_json::json!([true, "GUARDED_TOOL_REQUIRED"])
    );
}

#[test]
fn wait_returns_a_structured_error_for_an_invalid_timeout() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local value, err = async_task.wait('none', -1); return {value == nil, err.code, type(err.message)}",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(
        result.result,
        serde_json::json!([true, "VALIDATION", "string"])
    );
}

#[test]
fn unknown_task_returns_not_found() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local value, err = async_task.result('missing'); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "NOT_FOUND");
}

#[test]
fn generic_test_task_uses_the_shared_task_registry() {
    let runtime = LuaRuntime::new(None).unwrap();
    let execution = runtime
        .execute(
            "local id, err = sys.test.start_task(1, {answer=42}); if err then error(err.message) end; local value, wait_err = async_task.wait(id, 1000); if wait_err then error(wait_err.message) end; return value.answer",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(execution.result, serde_json::json!(42));
}

#[test]
fn async_cli_preserves_timeout_error_code() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        "demo = { __allowed_cli_commands = {'sh'} }",
    )
    .unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let execution = runtime
        .execute(
            "local id = sys.cli.start_text('sh', {'-c', 'while :; do :; done'}, {timeout=0.02}); local value, err = async_task.wait(id, 1000); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(execution.result, "TIMEOUT");
}

#[test]
fn cancelling_async_cli_stops_the_subprocess() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        "demo = { __allowed_cli_commands = {'sh'} }",
    )
    .unwrap();
    let marker = services.path().join("should-not-exist");
    let marker_lua = serde_json::to_string(marker.to_str().unwrap()).unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let execution = runtime
        .execute(
            &format!(
                "local id, err = sys.cli.start_text('sh', {{'-c', 'sleep 0.2; printf done > \"$1\"', 'sh', {marker_lua}}}); if err then error(err.message) end; return async_task.cancel(id)"
            ),
            ExecutionMode::Guarded,
            "<test>",
        )
        .unwrap();
    assert_eq!(execution.result, true);
    std::thread::sleep(std::time::Duration::from_millis(350));
    assert!(!marker.exists());
}
