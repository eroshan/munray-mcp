use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn vfs_roundtrips_text_and_preserves_session_files() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime.execute("local info, err = vfs.write_text('reports/a.txt', 'abcdef'); if err then error(err.message) end; return info.size", ExecutionMode::Guarded, "<test>").unwrap();
    let result = runtime.execute("local text, err = vfs.read_text('reports/a.txt', {offset=2, max_bytes=3}); if err then error(err.message) end; return text", ExecutionMode::ReadOnly, "<test>").unwrap();
    assert_eq!(result.result, "cde");
}

#[test]
fn vfs_rejects_path_traversal() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            "local value, err = vfs.write_text('../escape', 'no'); return err.code",
            ExecutionMode::Guarded,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, "VFS_ERROR");
}

#[test]
fn vfs_mutations_and_expose_require_guarded_mode() {
    let runtime = LuaRuntime::new(None).unwrap();
    for operation in [
        "vfs.mkdirp('dir')",
        "vfs.ensure_parent('dir/a.txt')",
        "vfs.write_text('a.txt', 'x')",
    ] {
        let result = runtime
            .execute(
                &format!("local value, err = {operation}; return err.code"),
                ExecutionMode::ReadOnly,
                "<test>",
            )
            .unwrap();
        assert_eq!(result.result, "GUARDED_TOOL_REQUIRED");
    }
    runtime
        .execute(
            "vfs.write_text('a.txt', 'x')",
            ExecutionMode::Guarded,
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
    assert_eq!(result.result, "GUARDED_TOOL_REQUIRED");
}
