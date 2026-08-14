use std::fs;

use mcp_server::runtime::LuaRuntime;

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
