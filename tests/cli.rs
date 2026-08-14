use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;

#[test]
fn help_lists_supported_commands() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("mcp"))
        .stdout(predicate::str::contains("run"))
        .stdout(predicate::str::contains("validate"))
        .stdout(predicate::str::contains("test"))
        .stdout(predicate::str::contains("stats"));
}

#[test]
fn list_sys_enumerates_registered_primitives() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .arg("list-sys")
        .assert()
        .success()
        .stdout(predicate::str::contains("sys.http.request"))
        .stdout(predicate::str::contains("sys.http.start_request"))
        .stdout(predicate::str::contains("sys.graphql.start_request"))
        .stdout(predicate::str::contains("sys.kv.put"))
        .stdout(predicate::str::contains("sys.snippets.save"));
}

#[test]
fn stdin_is_executed_as_lua_without_a_repl() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .write_stdin("print('hello from lua')\nreturn 6 * 7\n")
        .assert()
        .success()
        .stdout(predicate::str::contains("hello from lua"))
        .stdout(predicate::str::contains("42"));
}

#[test]
fn run_rejects_empty_stdin() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .arg("run")
        .write_stdin("")
        .assert()
        .failure()
        .stderr(predicate::str::contains("Lua code is required"));
}

#[test]
fn services_default_to_the_mcp_server_home_location() {
    let home = tempfile::tempdir().unwrap();
    let service_src = home.path().join(format!(
        ".local/share/{}/services/example/src",
        env!("CARGO_PKG_NAME")
    ));
    fs::create_dir_all(&service_src).unwrap();
    fs::write(
        service_src.join("init.lua"),
        "home_service = { value = 'loaded from default service directory' }",
    )
    .unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .env_remove("MUNRAY_MCP_SVC_DIR")
        .env_remove("MUNRAY_MCP_HOME")
        .env("HOME", home.path())
        .write_stdin("return home_service.value")
        .assert()
        .success()
        .stdout(predicate::str::contains(
            "loaded from default service directory",
        ));
}

#[test]
fn mcp_server_home_overrides_the_home_derived_location() {
    let data_home = tempfile::tempdir().unwrap();
    let service_src = data_home.path().join("services/example/src");
    fs::create_dir_all(&service_src).unwrap();
    fs::write(
        service_src.join("init.lua"),
        "configured_home_service = { value = 'loaded from MUNRAY_MCP_HOME' }",
    )
    .unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .env_remove("MUNRAY_MCP_SVC_DIR")
        .env("MUNRAY_MCP_HOME", data_home.path())
        .write_stdin("return configured_home_service.value")
        .assert()
        .success()
        .stdout(predicate::str::contains("loaded from MUNRAY_MCP_HOME"));
}

#[test]
fn stats_reports_function_usage_in_legacy_text_format() {
    let directory = tempfile::tempdir().unwrap();
    let store = directory.path().join("store.json");

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--store-path", store.to_str().unwrap()])
        .write_stdin("return json.encode({answer=42})")
        .assert()
        .success();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--store-path", store.to_str().unwrap(), "stats"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Function usage stats"))
        .stdout(predicate::str::contains(format!(
            "Store: {}",
            store.display()
        )))
        .stdout(predicate::str::contains("Summary"))
        .stdout(predicate::str::contains("By service"))
        .stdout(predicate::str::contains("Top functions by calls (top 20)"))
        .stdout(predicate::str::contains("json.encode"))
        .stdout(predicate::str::contains("Never used functions"));
}

#[test]
fn stats_reports_historical_service_usage_even_without_the_service_dir() {
    let directory = tempfile::tempdir().unwrap();
    let store = directory.path().join("store.json");
    let services = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("services");

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            services.to_str().unwrap(),
            "--store-path",
            store.to_str().unwrap(),
        ])
        .write_stdin(
            r#"
local _iter = gitlab.mr.list("group/project", { limit = 1 })
return true
"#,
        )
        .assert()
        .success();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--store-path", store.to_str().unwrap(), "stats"])
        .env_remove("MUNRAY_MCP_SVC_DIR")
        .env("MUNRAY_MCP_HOME", directory.path().join("empty-data-home"))
        .assert()
        .success()
        .stdout(predicate::str::contains("gitlab"))
        .stdout(predicate::str::contains("gitlab.mr.list"));
}
