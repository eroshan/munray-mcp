use assert_cmd::Command;
use predicates::prelude::*;

#[test]
fn saved_snippet_survives_a_new_cli_process() {
    let directory = tempfile::tempdir().unwrap();
    let store = directory.path().join("store.json");

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--store-path", store.to_str().unwrap()])
        .write_stdin(
            r#"local ok, err = store.save_snippet({path="local_tools.answer", code="function() return 42 end", description="Answers"}); if err then error(err.message) end; return ok"#,
        )
        .assert()
        .success();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--store-path", store.to_str().unwrap()])
        .write_stdin("return local_tools.answer()")
        .assert()
        .success()
        .stdout(predicate::str::contains("42"));

    let metadata = std::fs::metadata(store).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    }
}
