use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn ingested_text_is_session_local_and_repeatable() {
    let runtime = LuaRuntime::new(None).unwrap();
    let token = runtime.ingest_text("hello\nworld").unwrap();
    let code = format!(
        "local first = ingest.get('{token}'); local second = ingest.get('{token}'); return first == second and second"
    );
    let result = runtime
        .execute(&code, ExecutionMode::ReadOnly, "<test>")
        .unwrap();
    assert_eq!(result.result, "hello\nworld");
}

#[test]
fn invalid_ingest_token_is_structured() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local value, err = ingest.get('bad'); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "INVALID_TOKEN");
}
