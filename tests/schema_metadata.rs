use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};
use serde_json::Value;

#[test]
fn capability_json_schema_declares_guarded_and_rejects_obsolete_mutating() {
    let schema: Value =
        serde_json::from_str(include_str!("../src/assets/capabilities.schema.json")).unwrap();
    let function = &schema["$defs"]["FunctionSchema"];
    assert!(
        function["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "guarded")
    );
    assert_eq!(function["properties"]["guarded"]["type"], "boolean");
    assert!(function["properties"].get("mutating").is_none());
}

#[test]
fn inline_method_examples_override_same_key_file_examples() {
    let services = tempfile::tempdir().unwrap();
    let pack = services.path().join("demo");
    fs::create_dir_all(pack.join("src")).unwrap();
    fs::create_dir_all(pack.join("examples/resource")).unwrap();
    fs::write(
        pack.join("src/init.lua"),
        r#"
demo = {
  resource = {
    get = function() return {}, nil end,
    __schema = {
      namespace = "demo.resource", service = "demo", functions = {
        {
          name = "get", signature = "()", description = "Get.", guarded = false,
          returns_contract = "core.result",
          returns_typed = {
            { name = "result", type = "table" },
            { name = "err", type = "core.error|nil" },
          },
          examples = "return 'inline method example'",
        },
      },
    },
  },
}
"#,
    )
    .unwrap();
    fs::write(
        pack.join("examples/resource/get.lua"),
        "return 'file example'\n",
    )
    .unwrap();

    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let execution = runtime
        .execute(
            "return examples('demo.resource.get')",
            ExecutionMode::ReadOnly,
            "<inline-example-precedence>",
        )
        .unwrap();
    assert_eq!(
        execution.result,
        serde_json::json!("return 'inline method example'")
    );
}

#[test]
fn grouping_schema_guides_callers_to_full_nested_namespaces() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
demo = {
  __schema = {
    namespace = "demo", service = "demo", functions = {},
    resources = { "demo.alpha", "demo.admin" },
  },
  alpha = {
    __schema = { namespace = "demo.alpha", service = "demo", functions = {} },
  },
  admin = {
    __schema = { namespace = "demo.admin", service = "demo", functions = {} },
    user = {
      __schema = { namespace = "demo.admin.user", service = "demo", functions = {} },
    },
  },
}
"#,
    )
    .unwrap();

    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let execution = runtime
        .execute(
            r#"return {root = schema("demo"), leaf = schema("demo.alpha")}"#,
            ExecutionMode::ReadOnly,
            "<schema-navigation>",
        )
        .unwrap();

    assert_eq!(
        execution.result["root"]["nested_namespaces"],
        serde_json::json!(["demo.admin", "demo.admin.user", "demo.alpha"])
    );
    assert_eq!(
        execution.result["root"]["hint"],
        "This namespace groups nested APIs. Repeat schema() with a fully qualified namespace from nested_namespaces."
    );
    assert!(execution.result["leaf"].get("hint").is_none());
    assert!(execution.result["leaf"].get("nested_namespaces").is_none());
}

#[test]
fn discovered_schemas_keep_descriptors_unmodified_and_normalize_empty_lists() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
demo = {
  ping = function() return true, nil end,
  __schema = {
    namespace = "demo", service = "demo", functions = {
      {
        name = "ping", signature = "()", description = "Ping.", guarded = false,
        params = {},
        returns_contract = "core.result",
        returns_typed = {
          { name = "result", type = "boolean" },
          { name = "err", type = "core.error|nil" },
        },
      },
    },
  },
  empty = {
    __schema = { namespace = "demo.empty", service = "demo", functions = {} },
  },
}
"#,
    )
    .unwrap();

    let schemas = LuaRuntime::new(Some(services.path()))
        .unwrap()
        .discovered_schemas()
        .unwrap();
    let ping = &schemas["demo"]["functions"][0];

    assert!(ping.get("__mcp_server_wrapped").is_none());
    assert_eq!(ping["params"], serde_json::json!([]));
    assert_eq!(schemas["demo.empty"]["functions"], serde_json::json!([]));
}
