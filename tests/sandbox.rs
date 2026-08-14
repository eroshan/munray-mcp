use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn user_code_cannot_recover_restricted_stdlib() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "return io == nil and os == nil and debug == nil and package == nil and require == nil and dofile == nil and loadfile == nil",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}

#[test]
fn mutable_schema_cannot_relax_registered_mutation_policy() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
demo = { __schema = { namespace="demo", service="demo", functions={
  {name="change",mutating=true,returns_contract="core.result"},
} } }
function demo.change() _G.changed = true; return true, nil end
"#,
    )
    .unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let result = runtime
        .execute(
            "demo.__schema.functions[1].mutating=false; local value, err=demo.change(); return value == nil and err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "MUTATING_BLOCKED");
}

#[test]
fn wrapper_installer_is_not_visible_to_session_code() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "return _install_security_wrappers == nil and __install_security_wrappers == nil",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
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
        "local direct=demo.env(); local iter=demo.items(); local item=iter(); return direct and item and os == nil", 
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}
