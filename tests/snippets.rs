use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn snippets_install_immediately_and_allow_definition_updates() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "local ok, err=snippets.save({path='local_tools.math.double',code='function(x) return x*2 end'}); if err then error(err.message) end; local updated, update_err=snippets.save({path='local_tools.math.double',code='function() return 0 end'}); return {value=local_tools.math.double(6),updated=updated,error=update_err}",
        ExecutionMode::Mutating,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["value"], 0);
    assert_eq!(result.result["updated"], true);
    assert!(result.result["error"].is_null());
}

#[test]
fn saved_snippets_refresh_ai_context() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            r#"
assert(capabilities.ai_context().namespaces.local_tools == nil)
assert(snippets.save({namespace="local_tools", name="answer", code="function() return 42 end"}))
local context = capabilities.ai_context()
local callable = local_tools.answer()
assert(snippets.delete("local_tools", "answer"))
local after_delete = capabilities.ai_context()
return {
  callable=callable,
  discovered=context.namespaces.local_tools.answer ~= nil,
  removed=after_delete.namespaces.local_tools == nil,
}
"#,
            ExecutionMode::Mutating,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result["callable"], 42);
    assert_eq!(result.result["discovered"], true);
    assert_eq!(result.result["removed"], true);
}

#[test]
fn snippets_accept_namespace_name_and_named_lua_functions() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        r#"
local ok, err = snippets.save({
  namespace = "math", name = "fibonacci",
  code = [[function fibonacci(n)
    if n < 2 then return n end
    return math.fibonacci(n - 1) + math.fibonacci(n - 2)
  end]],
})
if err then error(err.message) end
local definition = assert(snippets.get("math", "fibonacci"))
local value = math.fibonacci(10)
assert(snippets.delete("math", "fibonacci"))
return {value=value, namespace=definition.namespace, name=definition.name, path=definition.path, deleted=math.fibonacci == nil}
"#,
        ExecutionMode::Mutating,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["value"], 55);
    assert_eq!(result.result["namespace"], "math");
    assert_eq!(result.result["name"], "fibonacci");
    assert!(result.result["path"].is_null());
    assert_eq!(result.result["deleted"], true);
}

#[test]
fn snippets_attach_schema_examples_and_can_be_recreated() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        r#"
snippets.save({path='local_tools.echo',code='function(x) return x end',schema_expr='{name="echo",path="local_tools.echo",description="Echoes input",mutating=false,returns_contract="core.result"}',example='return local_tools.echo(1)'})
local schema=capabilities.schema('local_tools')
local description, example=schema.functions[1].description,capabilities.examples('local_tools.echo')
snippets.delete('local_tools.echo')
local absent=local_tools == nil or local_tools.echo == nil
snippets.save({path='local_tools.echo',code='function() return 2 end'})
return {description=description,example=example,absent=absent,value=local_tools.echo()}
"#,
        ExecutionMode::Mutating,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["description"], "Echoes input");
    assert_eq!(result.result["example"], "return local_tools.echo(1)");
    assert_eq!(result.result["absent"], true);
    assert_eq!(result.result["value"], 2);
}

#[test]
fn dynamic_snippet_policy_is_captured_by_rust_wrapper() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime
        .execute(
            "assert(snippets.save({path='local_tools.change',code='function() return true end',schema_expr='{mutating=true}'}))",
            ExecutionMode::Mutating,
            "<test>",
        )
        .unwrap();
    let result = runtime
        .execute(
            "local_tools.__schema.functions[1].mutating=false; local value, err=local_tools.change(); return value == nil and err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "MUTATING_BLOCKED");
}

#[test]
fn save_snippet_definition_is_discoverable() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        r#"
local ok, err=snippets.save({path="local_tools.square",code="function(x) return x*x end",description="Squares input",params={{name="x",type="number"}},returns={{name="result",type="number"}},example="return local_tools.square(3)"})
if err then error(err.message) end
local schema=capabilities.schema("local_tools")
return {value=local_tools.square(4),description=schema.functions[1].description,example=capabilities.examples("local_tools.square")}
"#,
        ExecutionMode::Mutating,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["value"], 16);
    assert_eq!(result.result["description"], "Squares input");
    assert_eq!(result.result["example"], "return local_tools.square(3)");
}
