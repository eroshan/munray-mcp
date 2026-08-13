use std::path::Path;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

const GO_AI_CONTEXT: &str = include_str!("fixtures/go-ai-context.json");

#[test]
fn ai_context_matches_the_go_reference_exactly() {
    let services = Path::new(env!("CARGO_MANIFEST_DIR")).join("services");
    let runtime = LuaRuntime::new(Some(&services)).unwrap();

    let context = runtime
        .execute(
            "return capabilities.ai_context()",
            ExecutionMode::ReadOnly,
            "<ai-context-parity>",
        )
        .unwrap();
    let expected: serde_json::Value = serde_json::from_str(GO_AI_CONTEXT).unwrap();
    assert_eq!(context.result, expected);

    let encoded = runtime
        .execute(
            "return json.encode(capabilities.ai_context(), true)",
            ExecutionMode::ReadOnly,
            "<ai-context-encoding-parity>",
        )
        .unwrap();
    assert_eq!(encoded.result.as_str().unwrap(), GO_AI_CONTEXT.trim_end());
}
