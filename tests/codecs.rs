use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn yaml_codec_roundtrips_lua_tables() {
    let runtime = LuaRuntime::new(None).unwrap();
    let execution = runtime
        .execute(
            "local text = yaml.encode({name='luaris-mcp', values={1,2}}); local value = yaml.decode(text); return value",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(
        execution.result,
        serde_json::json!({"name":"luaris-mcp","values":[1,2]})
    );
}
