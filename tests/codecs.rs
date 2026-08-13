use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn yaml_codec_roundtrips_lua_tables() {
    let runtime = LuaRuntime::new(None).unwrap();
    let execution = runtime
        .execute(
            "local text = yaml.encode({name='munray-mcp', values={1,2}}); local value = yaml.decode(text); return value",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(
        execution.result,
        serde_json::json!({"name":env!("CARGO_PKG_NAME"),"values":[1,2]})
    );
}
