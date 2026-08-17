use assert_cmd::Command;
use predicates::prelude::*;
use std::fs;

fn valid_schema() -> &'static str {
    r#"
demo = {}
demo.__schema = {
  namespace = "demo", service = "demo",
  functions = {{
    name = "ping", signature = "()", returns_contract = "core.result",
    description = "Ping", guarded = false,
    returns_typed = {{name = "result", type = "boolean"}, {name = "err", type = "core.error|nil"}}
  }}
}
function demo.ping() return true, nil end
"#
}

#[test]
fn validate_discovers_schemas_and_reports_loaded_pack_and_nested_init_module() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(src.join("internal")).unwrap();
    fs::write(src.join("init.lua"), valid_schema()).unwrap();
    fs::write(src.join("internal/init.lua"), "demo.internal_loaded = true").unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--svc-dir", services.path().to_str().unwrap(), "validate"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Loaded service pack directories:"))
        .stdout(predicate::str::contains("demo ("))
        .stdout(predicate::str::contains("nested init.lua module(s):"))
        .stdout(predicate::str::contains("internal/init.lua"));
}

#[test]
fn validate_rejects_a_pack_without_the_required_root_entrypoint() {
    let services = tempfile::tempdir().unwrap();
    fs::create_dir_all(services.path().join("broken/src/internal")).unwrap();
    fs::write(
        services.path().join("broken/src/internal/init.lua"),
        "-- nested modules do not define a service pack",
    )
    .unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--svc-dir", services.path().to_str().unwrap(), "validate"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("missing required entrypoint"));
}

#[test]
fn validate_fails_when_capability_discovery_rejects_a_schema() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("broken/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
broken = { __schema = {
  namespace = "broken", service = "broken",
  functions = {{name = "bad"}}
}}
function broken.bad() end
"#,
    )
    .unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--svc-dir", services.path().to_str().unwrap(), "validate"])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Invalid __schema for broken"));
}
