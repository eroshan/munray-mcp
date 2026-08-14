use mcp_server::runtime::{ExecutionMode, LuaRuntime};

const CORE_AI_CONTEXT: &str = include_str!("fixtures/core-ai-context.json");

#[test]
fn core_ai_context_matches_the_reference_exactly() {
    // Service namespaces and hints are user-defined. Test the core schema in
    // isolation so installed services cannot affect this reference output.
    let runtime = LuaRuntime::new(None).unwrap();

    let context = runtime
        .execute(
            "return capabilities.ai_context()",
            ExecutionMode::ReadOnly,
            "<ai-context-parity>",
        )
        .unwrap();
    let expected: serde_json::Value = serde_json::from_str(CORE_AI_CONTEXT).unwrap();
    assert_eq!(context.result, expected);

    let encoded = runtime
        .execute(
            "return json.encode(capabilities.ai_context(), true)",
            ExecutionMode::ReadOnly,
            "<ai-context-encoding-parity>",
        )
        .unwrap();
    assert_eq!(encoded.result.as_str().unwrap(), CORE_AI_CONTEXT.trim_end());
}
