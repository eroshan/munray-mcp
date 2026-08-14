use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn kv_supports_namespaced_crud_and_sorted_keys() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "kv.put('note','b',{value=2}); kv.put('note','a',{value=1}); local keys=kv.keys('note'); local value=kv.get('note','a'); return {keys=keys,value=value.value,count=kv.len('note')}",
        ExecutionMode::Guarded,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["keys"], serde_json::json!(["a", "b"]));
    assert_eq!(result.result["value"], 1);
    assert_eq!(result.result["count"], 2);
}

#[test]
fn kv_has_no_core_cache_semantics() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "return kv.cache_get == nil and kv.cache_set == nil",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, true);
}
