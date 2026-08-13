use std::time::Duration;

use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn lua_instruction_timeout_interrupts_runaway_code() {
    let runtime = LuaRuntime::new(None).unwrap();
    let error = match runtime.execute_with_timeout(
        "while true do end",
        ExecutionMode::ReadOnly,
        "<timeout-test>",
        Some(Duration::from_millis(20)),
    ) {
        Ok(_) => panic!("runaway Lua unexpectedly completed"),
        Err(error) => error,
    };
    assert!(format!("{error:#}").contains("execution timeout"));
}
