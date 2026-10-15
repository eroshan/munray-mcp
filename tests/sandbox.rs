use std::fs;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

fn assert_restricted_session_libraries(runtime: &LuaRuntime, mode: ExecutionMode) {
    let result = runtime
        .execute(
            r#"
assert(type(os) == "table" and type(os.date) == "function")
assert(getmetatable(os) == nil)
-- Keep the expected exports independent of the runtime's policy constant.
for name in pairs(os) do assert(name == "date", "Unexpected os export: " .. name) end
return io == nil and debug == nil and package == nil and require == nil
    and dofile == nil and loadfile == nil and load == nil and sys == nil
"#,
            mode,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, true);
}

#[test]
fn user_code_cannot_recover_restricted_stdlib() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    for mode in [ExecutionMode::ReadOnly, ExecutionMode::Guarded] {
        assert_restricted_session_libraries(&runtime, mode);
    }
}

#[test]
fn session_os_date_preserves_standard_lua_behavior() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    for mode in [ExecutionMode::ReadOnly, ExecutionMode::Guarded] {
        let result = runtime
            .execute(
                r#"
assert(type(os.date()) == "string")
assert(type(os.date("!%Y")) == "string")
return {formatted=os.date("!%Y-%m-%dT%H:%M:%SZ", 0), fields=os.date("!*t", 0)}
"#,
                mode,
                "<test>",
            )
            .unwrap();
        assert_eq!(
            result.result,
            serde_json::json!({
                "formatted": "1970-01-01T00:00:00Z",
                "fields": {
                    "year": 1970, "month": 1, "day": 1,
                    "hour": 0, "min": 0, "sec": 0,
                    "wday": 5, "yday": 1, "isdst": false,
                },
            })
        );
    }
}

#[test]
fn session_library_exports_are_rebuilt_after_snippet_changes() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    assert_restricted_session_libraries(&runtime, ExecutionMode::ReadOnly);
    runtime
        .execute(
            r#"
local previous = os
os.date = false
os.injected = true
setmetatable(os, {__index={getenv=function() return "fake" end}})
assert(snippets.save({namespace="probe", name="year", code='function() return os.date("!%Y", 0) end'}))
assert(os ~= previous and probe.year() == "1970")
"#,
            ExecutionMode::Guarded,
            "<test>",
        )
        .unwrap();
    assert_restricted_session_libraries(&runtime, ExecutionMode::ReadOnly);
    runtime
        .execute(
            r#"
local previous = os
os = nil
assert(snippets.delete("probe", "year"))
assert(os ~= previous and os.date("!%Y", 0) == "1970")
"#,
            ExecutionMode::Guarded,
            "<test>",
        )
        .unwrap();
    assert_restricted_session_libraries(&runtime, ExecutionMode::ReadOnly);
}

#[test]
fn session_library_tables_are_isolated_from_trusted_globals() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
local original_date = os.date
local original_metatable = {__index={hidden=true}}
setmetatable(os, original_metatable)
-- Schema metadata must not cause the entire os table to be exposed.
os.__schema = {namespace="os", service="demo", functions={}}
demo = {__schema={namespace="demo", service="demo", functions={
    {name="intact", returns_contract="core.result", guarded=false},
}}}
function demo.intact()
    return os.date == original_date and type(os.getenv) == "function"
        and os.injected == nil and getmetatable(os) == original_metatable, nil
end
"#,
    )
    .unwrap();
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    assert_restricted_session_libraries(&runtime, ExecutionMode::ReadOnly);
    runtime
        .execute(
            r#"
os.date = function() return "fake" end
os.injected = true
setmetatable(os, {})
assert(demo.intact())
"#,
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    let other = LuaRuntime::new_session(None).unwrap();
    assert_restricted_session_libraries(&other, ExecutionMode::ReadOnly);
}

#[test]
fn session_library_exports_must_be_functions() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    for value in ["nil", "{}"] {
        fs::write(src.join("init.lua"), format!("os.date = {value}")).unwrap();
        let error = LuaRuntime::new_session(Some(services.path()))
            .err()
            .unwrap();
        assert!(
            error
                .to_string()
                .contains("Invalid session library export os.date"),
            "{error:#}"
        );
    }
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
  {name="change",guarded=true,returns_contract="core.result"},
} } }
function demo.change() _G.changed = true; return true, nil end
"#,
    )
    .unwrap();
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    let result = runtime
        .execute(
            "demo.__schema.functions[1].guarded=false; local value, err=demo.change(); return value == nil and err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "GUARDED_TOOL_REQUIRED");
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
  {name="get",guarded=true,returns_contract="core.result"},
} } }
beta = { __schema = { namespace="beta", service="demo", functions={
  {name="get",guarded=true,returns_contract="core.result"},
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
    assert_eq!(result.result["a"], "GUARDED_TOOL_REQUIRED");
    assert_eq!(result.result["b"], "GUARDED_TOOL_REQUIRED");
}

#[test]
fn schema_paths_do_not_override_derived_operation_paths() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
alpha = { __schema = { namespace="alpha", service="demo", functions={
  {name="one",path="duplicate.path",guarded=false,returns_contract="core.result"},
  {name="two",path="duplicate.path",guarded=false,returns_contract="core.result"},
} } }
function alpha.one() return true, nil end
function alpha.two() return true, nil end
"#,
    )
    .unwrap();
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    let paths = runtime.eligible_function_paths().unwrap();
    assert!(paths.contains(&"alpha.one".to_owned()));
    assert!(paths.contains(&"alpha.two".to_owned()));
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
  {name="env",returns_contract="core.result",guarded=false},
  {name="items",returns_contract="core.iter",guarded=false},
} } }
function demo.env() return os.getenv("PATH") ~= nil, nil end
function demo.items() local done=false; return function() if done then return nil end; done=true; return os.getenv("PATH") ~= nil end end
"#).unwrap();
    let runtime = LuaRuntime::new_session(Some(services.path())).unwrap();
    let result = runtime.execute(
        "local direct=demo.env(); local iter=demo.items(); local item=iter(); return direct and item and os.getenv == nil",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result, true);
}
