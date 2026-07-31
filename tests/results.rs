use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn multiple_results_are_returned_as_an_array_and_trailing_nil_is_trimmed() {
    let runtime = LuaRuntime::new(None).unwrap();
    let execution = runtime
        .execute(
            "return 1, 'two', true, nil",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(execution.result, serde_json::json!([1, "two", true]));
}
