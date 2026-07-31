use std::{thread, time::Duration};

use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn store_supports_crud_and_sorted_keys() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime.execute(
        "store.put('note','b',{value=2}); store.put('note','a',{value=1}); local keys=store.keys('note'); local value=store.get('note','a'); return {keys=keys,value=value.value,count=store.len('note')} ",
        ExecutionMode::Mutating,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["keys"], serde_json::json!(["a", "b"]));
    assert_eq!(result.result["value"], 1);
    assert_eq!(result.result["count"], 2);
}

#[test]
fn cache_entries_expire() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime
        .execute(
            "store.cache_set('short',{ok=true},0)",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    thread::sleep(Duration::from_millis(1));
    let result = runtime
        .execute(
            "return store.cache_get('short')",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert!(result.result.is_null());
}
