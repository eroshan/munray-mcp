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
        .args([
            "--svc-dir",
            services.path().to_str().unwrap(),
            "svc",
            "validate",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Loaded service pack directories:"))
        .stdout(predicate::str::contains("demo ("))
        .stdout(predicate::str::contains("nested init.lua module(s):"))
        .stdout(predicate::str::contains("internal/init.lua"));
}

#[cfg(unix)]
#[test]
fn symlinked_service_pack_is_listed_loaded_and_updated() {
    use std::os::unix::fs::symlink;

    let root = tempfile::tempdir().unwrap();
    let services = root.path().join("services");
    let pack = root.path().join("checkout");
    fs::create_dir(&services).unwrap();
    fs::create_dir_all(pack.join("src")).unwrap();
    fs::write(pack.join("src/init.lua"), valid_schema()).unwrap();
    symlink("../checkout", services.join("demo")).unwrap();
    symlink("../missing", services.join("broken")).unwrap();
    symlink("../checkout", services.join(".hidden")).unwrap();
    symlink("../checkout/src/init.lua", services.join("file_link")).unwrap();
    let services_link = root.path().join("services-link");
    symlink("services", &services_link).unwrap();

    let command = || {
        let mut command = Command::cargo_bin(env!("CARGO_PKG_NAME")).unwrap();
        command
            .arg("--svc-dir")
            .arg(&services_link)
            .arg("--store-path")
            .arg(root.path().join("store.db"));
        command
    };

    command()
        .args(["svc", "list"])
        .assert()
        .success()
        .stdout(format!(
            "Service packs in {}:\n  demo\n",
            services_link.display()
        ));

    for args in [&["svc", "validate"][..], &["svc", "validate", "demo"]] {
        command()
            .args(args)
            .assert()
            .success()
            .stdout(predicate::str::contains("Loaded service pack directories:"))
            .stdout(predicate::str::contains(format!(
                "demo ({})",
                services_link.join("demo").display()
            )));
    }

    command()
        .arg("run")
        .write_stdin(
            "assert(ctx_init().namespaces.demo.ping); assert(demo.ping()); print('loaded')",
        )
        .assert()
        .success()
        .stdout("loaded\n");

    command()
        .args(["svc", "bootstrap", "--update"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Updated").count(1));
    assert!(
        pack.join(".agents/skills/munray-service-pack/SKILL.md")
            .is_file()
    );
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
        .args([
            "--svc-dir",
            services.path().to_str().unwrap(),
            "svc",
            "validate",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("missing required entrypoint"));
}

#[test]
fn validate_rejects_properties_disallowed_by_the_capability_json_schema() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("broken/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        valid_schema().replace("guarded = false,", "guarded = false, mutating = true,"),
    )
    .unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            services.path().to_str().unwrap(),
            "svc",
            "validate",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains(
            "unknown property: functions[1].mutating",
        ));
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
        .args([
            "--svc-dir",
            services.path().to_str().unwrap(),
            "svc",
            "validate",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("Invalid __schema for broken"));
}
