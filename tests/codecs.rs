use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn base64_codecs_preserve_bytes_in_read_only_sessions() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    let execution = runtime
        .execute(
            r#"
local bytes = string.char(0, 255, 128, 254)
return {
  base64.encode("hello"),
  base64.decode("aGVsbG8="),
  base64.encode(bytes),
  base64.decode("AP+A/g==") == bytes,
  base64.encode("") == "" and base64.decode("") == "",
  schema("base64.decode").functions[1].guarded,
}
"#,
            ExecutionMode::ReadOnly,
            "<base64>",
        )
        .unwrap();
    assert_eq!(
        execution.result,
        serde_json::json!(["aGVsbG8=", "hello", "AP+A/g==", true, true, false])
    );
}

#[test]
fn service_pack_can_use_base64_at_load_time_and_in_a_schema_wrapper() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
local encoded = assert(base64.encode("hello"))
assert(encoded == "aGVsbG8=")
demo = {
  decode = function() return base64.decode(encoded) end,
  __schema = {
    namespace = "demo", service = "demo",
    functions = {{
      name = "decode", signature = "()", description = "Decode a test value.", guarded = false,
      returns_contract = "core.result",
      returns_typed = {{name = "result", type = "string"}, {name = "err", type = "core.error|nil"}},
    }},
  },
}
"#,
    )
    .unwrap();

    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    let execution = runtime
        .execute("return demo.decode()", ExecutionMode::ReadOnly, "<base64>")
        .unwrap();
    assert_eq!(execution.result, "hello");
}

#[test]
fn yaml_codec_roundtrips_lua_tables() {
    let runtime = LuaRuntime::new(None).unwrap();
    let execution = runtime
        .execute(
            "local text = yaml.encode({name='munray', values={1,2}}); local value = yaml.decode(text); return value",
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
fn string_codecs_return_structured_validation_errors_for_non_strings() {
    let runtime = LuaRuntime::new(None).unwrap();
    for codec in [
        "json.decode",
        "yaml.decode",
        "base64.encode",
        "base64.decode",
    ] {
        let execution = runtime
            .execute(
                &format!(
                    "local value, err = {codec}(42); return {{value == nil, err.code, type(err.message)}}"
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
        ("base64.decode", "BASE64_DECODE_FAILED"),
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
        ("base64.decode", "aGVsbG8", "BASE64_DECODE_FAILED"),
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
