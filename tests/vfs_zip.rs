use std::fs;

use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn zip_is_extracted_with_text_previews() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        "demo = { __allowed_cli_commands = {'zip'} }",
    )
    .unwrap();
    let fixture = tempfile::tempdir().unwrap();
    fs::write(fixture.path().join("readme.txt"), "hello archive").unwrap();
    fs::write(fixture.path().join("binary.bin"), [0_u8, 1, 2]).unwrap();
    let cwd = fixture.path().to_string_lossy();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let code = format!(
        "local blob, err = _raw.blob.from_cli('zip', {{'-q','-','readme.txt','binary.bin'}}, {{cwd={cwd:?}}}); if err then error(err.message) end; _raw.vfs.write_blob('test.zip', blob); local result, text_err=vfs.to_txt('test.zip'); if text_err then error(text_err.message) end; return result"
    );
    let result = runtime
        .execute(&code, ExecutionMode::ReadOnly, "<test>")
        .unwrap();
    assert_eq!(result.result["kind"], "zip");
    assert_eq!(result.result["files"].as_array().unwrap().len(), 2);
    assert_eq!(result.result["files"][0]["preview"], "hello archive");
}
