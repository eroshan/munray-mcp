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

#[test]
fn encoders_return_structured_errors_for_unsupported_values() {
    let runtime = LuaRuntime::new(None).unwrap();
    for (encoder, expected_code) in [
        ("json.encode", "JSON_ENCODE_FAILED"),
        ("yaml.encode", "YAML_ENCODE_FAILED"),
    ] {
        let execution = runtime
            .execute(
                &format!(
                    "local value, err = {encoder}({{[{{}}] = 'x'}}); return {{value == nil, err.code, type(err.message)}}"
                ),
                ExecutionMode::ReadOnly,
                "<test>",
            )
            .unwrap();
        assert_eq!(
            execution.result,
            serde_json::json!([true, expected_code, "string"])
        );
    }
}

#[test]
fn decoders_return_structured_validation_errors_for_non_strings() {
    let runtime = LuaRuntime::new(None).unwrap();
    for decoder in ["json.decode", "yaml.decode"] {
        let execution = runtime
            .execute(
                &format!(
                    "local value, err = {decoder}(42); return {{value == nil, err.code, type(err.message)}}"
                ),
                ExecutionMode::ReadOnly,
                "<test>",
            )
            .unwrap();
        assert_eq!(
            execution.result,
            serde_json::json!([true, "INVALID_FIELD_VALUE", "string"])
        );
    }
}

#[test]
fn decoders_return_structured_errors_for_invalid_utf8() {
    let runtime = LuaRuntime::new(None).unwrap();
    for (decoder, expected_code) in [
        ("json.decode", "JSON_DECODE_FAILED"),
        ("yaml.decode", "YAML_DECODE_FAILED"),
    ] {
        let execution = runtime
            .execute(
                &format!(
                    "local value, err = {decoder}(string.char(255)); return {{value == nil, err.code, type(err.message)}}"
                ),
                ExecutionMode::ReadOnly,
                "<test>",
            )
            .unwrap();
        assert_eq!(
            execution.result,
            serde_json::json!([true, expected_code, "string"])
        );
    }
}

#[test]
fn decoders_return_structured_errors_for_invalid_input() {
    let runtime = LuaRuntime::new(None).unwrap();
    for (decoder, input, expected_code) in [
        ("json.decode", "{bad", "JSON_DECODE_FAILED"),
        ("yaml.decode", "a: [unterminated", "YAML_DECODE_FAILED"),
    ] {
        let execution = runtime
            .execute(
                &format!("local value, err = {decoder}({input:?}); return {{value == nil, err.code, type(err.message)}}"),
                ExecutionMode::ReadOnly,
                "<test>",
            )
            .unwrap();
        assert_eq!(
            execution.result,
            serde_json::json!([true, expected_code, "string"])
        );
    }
}
