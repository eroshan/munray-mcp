use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn vfs_roundtrips_text_and_preserves_session_files() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime.execute("local info, err = vfs.write_text('reports/a.txt', 'abcdef'); if err then error(err.message) end; return info.size", ExecutionMode::ReadOnly, "<test>").unwrap();
    let result = runtime.execute("local text, err = vfs.read_text('reports/a.txt', {offset=2, max_bytes=3}); if err then error(err.message) end; return text", ExecutionMode::ReadOnly, "<test>").unwrap();
    assert_eq!(result.result, "cde");
}

#[test]
fn vfs_rejects_path_traversal() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local value, err = vfs.write_text('../escape', 'no'); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "VFS_ERROR");
}

#[test]
fn vfs_expose_requires_mutating_mode() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime
        .execute(
            "vfs.write_text('a.txt', 'x')",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    let result = runtime
        .execute(
            "local value, err = vfs.expose({'a.txt'}); return err.code",
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "MUTATING_BLOCKED");
}
