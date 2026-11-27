use mcp_server::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn vfs_roundtrips_text_and_preserves_session_files() {
    let runtime = LuaRuntime::new(None).unwrap();
    runtime.execute("local info, err = vfs.write_text('reports/a.txt', 'abcdef'); if err then error(err.message) end; return info.size", ExecutionMode::ReadOnly, "<test>").unwrap();
    let result = runtime.execute("local text, err = vfs.read_text('reports/a.txt', {offset=2, max_bytes=3}); if err then error(err.message) end; return text", ExecutionMode::ReadOnly, "<test>").unwrap();
    assert_eq!(result.result, "cde");
}

#[test]
fn vfs_leading_slashes_are_vfs_relative() {
    let runtime = LuaRuntime::new(None).unwrap();
    let result = runtime
        .execute(
            r#"
                local ok, err = vfs.mkdirp('/reports/nested')
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
    let runtime = LuaRuntime::new_session(None).unwrap();
    for operation in [
        "vfs.mkdirp('../escape')",
        "vfs.write_text('../escape', 'no')",
        "vfs.remove('../escape')",
    ] {
        let result = runtime
            .execute(
                &format!("local value, err = {operation}; return err.code"),
                ExecutionMode::ReadOnly,
                "<test>",
            )
            .unwrap();
        assert_eq!(result.result, "VFS_ERROR");
    }
}

#[test]
fn vfs_rejects_removing_root_and_preserves_files() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    runtime
        .execute(
            r#"
            local file = "reports/nested/a.txt"
            assert(vfs.write_text(file, "contents"))
            for _, root in ipairs({".", "./", "/.", "././"}) do
                local removed, err = vfs.remove(root)
                assert(removed == nil and err and err.code == "VFS_ERROR", root)
                assert(vfs.read_text(file) == "contents", root)
            end
            "#,
            ExecutionMode::ReadOnly,
            "<vfs-root-removal>",
        )
        .unwrap();
}

#[test]
fn vfs_removes_subtrees_addressed_with_trailing_dots() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    runtime
        .execute(
            r#"
            assert(vfs.write_text("keep.txt", "untouched"))
            for _, directory in ipairs({"reports/.", "reports/./", "./reports//./"}) do
                assert(vfs.write_text("reports/nested/a.txt", "contents"))
                local removed, err = vfs.remove(directory)
                assert(removed, err and err.message or directory)
                assert(vfs.stat("reports") == nil, directory)
            end
            assert(not vfs.remove("keep.txt/."))
            assert(vfs.read_text("keep.txt") == "untouched")
            "#,
            ExecutionMode::ReadOnly,
            "<vfs-directory-alias-removal>",
        )
        .unwrap();
}

#[test]
fn vfs_schema_only_guards_expose() {
    let runtime = LuaRuntime::new_session(None).unwrap();
    let result = runtime
        .execute(
            r#"
            local guarded = {}
            for _, fn in ipairs(schema("vfs").functions) do
                if fn.guarded then table.insert(guarded, fn.name) end
            end
            local _, err = schema("vfs.ensure_parent")
            assert(vfs.ensure_parent == nil and err.code == "NOT_FOUND")
            return guarded
            "#,
            ExecutionMode::ReadOnly,
            "<test>",
        )
        .unwrap();
    assert_eq!(result.result, serde_json::json!(["expose"]));
}
