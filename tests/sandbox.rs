use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn user_code_cannot_recover_restricted_stdlib() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "local io_ok = io == nil; local os_ok = os.getenv == nil and os.execute == nil; local require_ok = not pcall(require, 'io'); return io_ok and os_ok and require_ok",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}

#[test]
fn service_functions_and_iterator_steps_receive_full_stdlib() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(src.join("init.lua"), r#"
demo = { __schema = { namespace="demo", service="demo", functions={
  {name="env",returns_contract="core.result",mutating=false},
  {name="items",returns_contract="core.iter",mutating=false},
} } }
function demo.env() return os.getenv("PATH") ~= nil, nil end
function demo.items() local done=false; return function() if done then return nil end; done=true; return os.getenv("PATH") ~= nil end end
"#).unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let result = runtime.execute(
        "local direct=demo.env(); local iter=demo.items(); local item=iter(); return direct and item and os.getenv == nil",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}
