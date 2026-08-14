use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn user_code_cannot_recover_restricted_stdlib() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    let result = runtime.execute(
        "return io == nil and os == nil and debug == nil and package == nil and require == nil and dofile == nil and loadfile == nil and load == nil",
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
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
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
fn unqualified_schema_names_are_scoped_to_their_namespace() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
alpha = { __schema = { namespace="alpha", service="demo", functions={
  {name="get",mutating=true,returns_contract="core.result"},
} } }
beta = { __schema = { namespace="beta", service="demo", functions={
  {name="get",mutating=true,returns_contract="core.result"},
} } }
function alpha.get() return "alpha", nil end
function beta.get() return "beta", nil end
"#,
    )
    .unwrap();
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    let result = runtime
        .execute(
            "local a, ae=alpha.get(); local b, be=beta.get(); return {a=ae.code,b=be.code}",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result["a"], "MUTATING_BLOCKED");
    assert_eq!(result.result["b"], "MUTATING_BLOCKED");
}

#[test]
fn duplicate_schema_paths_fail_runtime_construction() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
alpha = { __schema = { namespace="alpha", service="demo", functions={
  {name="one",path="duplicate.path",mutating=false,returns_contract="core.result"},
  {name="two",path="duplicate.path",mutating=false,returns_contract="core.result"},
} } }
function alpha.one() return true, nil end
function alpha.two() return true, nil end
"#,
    )
    .unwrap();
    let error = match LuaRuntime::new_session(Some(services.path())) {
        Ok(_) => panic!("duplicate schema paths must fail runtime construction"),
        Err(error) => error,
    };
    assert!(
        error
            .to_string()
            .contains("duplicate schema function path: duplicate.path")
    );
}

#[test]
fn wrapper_installer_is_not_visible_to_session_code() {
    let runtime = LuaRuntime::new_session(None).unwrap();
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
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    let result = runtime.execute(
        "local direct=demo.env(); local iter=demo.items(); local item=iter(); return direct and item and os == nil", 
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}
