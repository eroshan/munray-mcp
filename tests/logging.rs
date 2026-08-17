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
    assert_eq!(stats.guarded, 1);

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

#[test]
fn logs_redact_execution_values_unless_raw_logging_is_explicitly_enabled() {
    let directory = tempfile::tempdir().unwrap();
    mcp_server::logging::Logger::new(directory.path())
        .unwrap()
        .log(mcp_server::logging::ExecutionEntry {
            timestamp_ms: 0,
            session_id: "test".into(),
            mode: "readonly".into(),
            code: "return 'secret-token'".into(),
            output: "secret-token".into(),
            result: serde_json::json!("secret-token"),
            error: Some("secret-token".into()),
            duration_ms: 0,
        })
        .unwrap();
    let line = std::fs::read_to_string(directory.path().join("executions.jsonl")).unwrap();
    assert!(!line.contains("secret-token"));
    assert!(line.contains("[redacted]"));
}
