use assert_cmd::Command;

#[test]
fn logged_cli_execution_is_written_to_owner_only_jsonl() {
    let directory = tempfile::tempdir().unwrap();
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--logs-dir", directory.path().to_str().unwrap()])
        .write_stdin("return 42")
        .assert()
        .success();

    let stats = mcp_server::logging::read_stats(directory.path()).unwrap();
    assert_eq!(stats.executions, 1);
    assert_eq!(stats.mutating, 1);

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(directory.path().join("executions.jsonl"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }
}
