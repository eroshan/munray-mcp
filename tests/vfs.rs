use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn vfs_roundtrips_text_and_preserves_session_files() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime.execute("local info, err = vfs.write_text('reports/a.txt', 'abcdef'); if err then error(err.message) end; return info.size", ExecutionMode::Guarded, "<test>").unwrap();
    let result = runtime.execute("local text, err = vfs.read_text('reports/a.txt', {offset=2, max_bytes=3}); if err then error(err.message) end; return text", ExecutionMode::ReadOnly, "<test>").unwrap();
    assert_eq!(result.result, "cde");
}

#[test]
fn vfs_leading_slashes_are_vfs_relative() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            r#"
                local ok, err = vfs.mkdirp('/reports')
                if err then error(err.message) end
                ok, err = vfs.ensure_parent('/reports/nested/a.txt')
                if err then error(err.message) end
                local info, write_err = vfs.write_text('/reports/nested/a.txt', 'contents')
                if write_err then error(write_err.message) end
                local text, read_err = vfs.read_text('/reports/nested/a.txt')
                if read_err then error(read_err.message) end
                local stat, stat_err = vfs.stat('/reports/nested/a.txt')
                if stat_err then error(stat_err.message) end
                local files, expose_err = vfs.expose({'/reports/nested/a.txt'})
                if expose_err then error(expose_err.message) end
                local removed, remove_err = vfs.remove('/reports/nested/a.txt')
                if remove_err then error(remove_err.message) end
                return {path=info.path, text=text, stat_path=stat.path, exposed_path=files.files[1].original_vfs_path, removed=removed}
            "#,
            ExecutionMode::Guarded,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result["path"], "reports/nested/a.txt");
    assert_eq!(result.result["text"], "contents");
    assert_eq!(result.result["stat_path"], "reports/nested/a.txt");
    assert_eq!(result.result["exposed_path"], "reports/nested/a.txt");
    assert_eq!(result.result["removed"], true);
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
