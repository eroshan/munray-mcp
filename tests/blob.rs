use std::fs;

use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

#[test]
fn cli_blob_can_be_measured_and_written_to_vfs() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        "demo = { __allowed_cli_commands = {'sh'} }",
    )
    .unwrap();
    let runtime = LuaRuntime::new(Some(services.path())).unwrap();
    let result = runtime.execute(
        "local blob, err = _raw.blob.from_cli('sh', {'-c', 'printf abc'}); if err then error(err.message) end; local size = _raw.blob.len(blob); local info, write_err = _raw.vfs.write_blob('blob.bin', blob); if write_err then error(write_err.message) end; local text = vfs.read_text('blob.bin'); return {size=size, text=text, label=tostring(blob)}",
        ExecutionMode::ReadOnly,
        "<test>",
    ).unwrap();
    assert_eq!(result.result["size"], 3);
    assert_eq!(result.result["text"], "abc");
    assert_eq!(result.result["label"], "blob(3 bytes)");
}
