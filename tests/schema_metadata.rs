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
      list = function() return function() end end,
      __schema = {
        namespace = "demo.admin.user", service = "demo",
        types = {
          Filter = { shape = "{query:string}" },
          ["Issue-Result"] = { shape = "{Ignored?:string, details:Issue+Detail[], children:Issue-Result[]}" },
          ["Issue+Detail"] = { shape = "{value:string}" },
          Issue = { shape = "{unrelated:string}" },
          Ignored = { shape = "{value:string}" },
        },
        functions = {
          {
            name = "list", signature = "(opts)", description = "List users.", guarded = false,
            returns_contract = "core.iter", yields = "Issue-Result",
            params = {{
              name = "opts", type = "table", schema = { filter = {type = "Filter|nil"} },
            }},
            returns_typed = {{name = "iterator", type = "Iterator"}},
          },
        },
      },
    },
  },
}
"#,
    )
    .unwrap();

    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let execution = runtime
        .execute(
            r#"
return {
  root = schema("demo"),
  leaf = schema("demo.alpha"),
  method = schema("demo.admin.user.list"),
}
"#,
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
    let method = &execution.result["method"];
    assert_eq!(method["namespace"], "demo.admin.user");
    assert_eq!(method["functions"][0]["yields"], "Issue-Result");
    assert_eq!(
        method["types"],
        serde_json::json!({
            "Filter": {"shape": "{query:string}"},
            "Issue-Result": {"shape": "{Ignored?:string, details:Issue+Detail[], children:Issue-Result[]}"},
            "Issue+Detail": {"shape": "{value:string}"},
        })
    );
}

#[test]
fn function_schema_returns_one_descriptor_and_its_types() {
    let runtime = LuaRuntime::new(None).unwrap();
    let schema = runtime
        .execute(
            r#"
return {
  stat = schema("vfs.stat"),
  expose = schema("vfs.expose"),
  full = schema("vfs"),
}
"#,
            ExecutionMode::ReadOnly,
            "<function-schema>",
        )
        .unwrap()
        .result;

    let full = &schema["full"];
    let stat = &schema["stat"];
    let functions = stat["functions"].as_array().unwrap();
    assert_eq!(stat["namespace"], "vfs");
    assert_eq!(stat["service"], "core");
    assert_eq!(functions.len(), 1);
    assert_eq!(
        &functions[0],
        full["functions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|function| function["name"] == "stat")
            .unwrap()
    );
    assert_eq!(
        stat["types"],
        serde_json::json!({"FileInfo": full["types"]["FileInfo"]})
    );

    let expose = &schema["expose"];
    assert_eq!(expose["functions"][0]["guarded"], true);
    assert_eq!(
        expose["types"],
        serde_json::json!({
            "ExposeResult": full["types"]["ExposeResult"],
            "ExposedFile": full["types"]["ExposedFile"],
        })
    );
}

#[test]
fn schema_accepts_multiple_namespaces_and_function_paths() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    runtime
        .execute(
            r#"
local namespaces = schema("vfs", "async_task")
assert(namespaces.vfs.namespace == "vfs" and #namespaces.vfs.functions > 1)
assert(namespaces.async_task.namespace == "async_task" and #namespaces.async_task.functions > 1)

local functions = schema("vfs.stat", "vfs.read_text")
assert(#functions["vfs.stat"].functions == 1)
assert(functions["vfs.stat"].functions[1].name == "stat")
assert(#functions["vfs.read_text"].functions == 1)
assert(functions["vfs.read_text"].functions[1].name == "read_text")
assert(functions["vfs.read_text"].types == nil)

local mixed = schema("async_task", "vfs.stat")
assert(mixed.async_task.namespace == "async_task")
assert(mixed["vfs.stat"].functions[1].name == "stat")
assert(select('#', schema("vfs")) == 1)

local missing, missing_err = schema("vfs.stat", "vfs.missing")
assert(missing == nil and missing_err.code == "NOT_FOUND")
assert(missing_err.message:find("vfs.missing", 1, true))
local invalid, invalid_err = schema("vfs.stat", nil, "async_task")
assert(invalid == nil and invalid_err.code == "INVALID_ARGUMENT")
"#,
            ExecutionMode::ReadOnly,
            "<batch-schema>",
        )
        .unwrap();
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
