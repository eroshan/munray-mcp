use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn snippets_install_immediately_and_reject_overrides() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "local ok, err=store.put('fn','local_tools.math.double','function(x) return x*2 end',{content_type='lua'}); if err then error(err.message) end; local duplicate, duplicate_err=store.put('fn','local_tools.math.double','function() return 0 end',{content_type='lua'}); return {value=local_tools.math.double(6),code=duplicate_err.code}",
        ExecutionMode::Mutating,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["value"], 12);
    assert_eq!(result.result["code"], "ALREADY_EXISTS");
}

#[test]
fn snippets_attach_schema_examples_and_can_be_recreated() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        r#"
store.put('fn','local_tools.echo','function(x) return x end',{content_type='lua'})
store.put('schema','local_tools.echo','{name="echo",path="local_tools.echo",description="Echoes input",mutating=false,returns_contract="core.result"}',{content_type='lua'})
store.put('example','local_tools.echo','"return local_tools.echo(1)"',{content_type='lua'})
local schema=capabilities.schema('local_tools')
local description, example=schema.functions[1].description,capabilities.examples('local_tools.echo')
store.delete('fn','local_tools.echo')
local absent=local_tools.echo == nil
store.put('fn','local_tools.echo','function() return 2 end',{content_type='lua'})
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
fn save_snippet_definition_is_discoverable() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        r#"
local ok, err=store.save_snippet({path="local_tools.square",code="function(x) return x*x end",description="Squares input",params={{name="x",type="number"}},returns={{name="result",type="number"}},example="return local_tools.square(3)"})
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
