use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn query_and_path_escaping_match_the_contract() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "local q=_raw.url.query_escape('a b/c+d'); local p=_raw.url.path_escape('a b/c+d'); local qu=_raw.url.query_unescape(q); local pu=_raw.url.path_unescape(p); return {q=q,p=p,qu=qu,pu=pu}",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["q"], "a+b%2Fc%2Bd");
    assert_eq!(result.result["p"], "a%20b%2Fc+d");
    assert_eq!(result.result["qu"], "a b/c+d");
    assert_eq!(result.result["pu"], "a b/c+d");
}

#[test]
fn invalid_percent_escape_returns_context() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "local value, err=_raw.url.query_unescape('bad%zz'); return {value=value,code=err.code,input=err.context.value}",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert!(result.result["value"].is_null());
    assert_eq!(result.result["code"], "VALIDATION");
    assert_eq!(result.result["input"], "bad%zz");
}
