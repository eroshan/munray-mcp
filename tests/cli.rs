use assert_cmd::Command;
use mcp_server::{runtime::LuaRuntime, sys_catalog};
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
        .stdout(predicate::str::contains("sys"))
        .stdout(predicate::str::contains("svc"))
        .stdout(predicate::str::contains("help"))
        .stdout(predicate::str::contains("test"))
        .stdout(predicate::str::contains("stats"));
}

#[test]
fn sys_and_svc_expose_their_nested_subcommands() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["sys", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("list"));
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["svc", "--help"])
        .assert()
        .success()
        .stdout(predicate::str::contains("bootstrap"))
        .stdout(predicate::str::contains("list"))
        .stdout(predicate::str::contains("uninstall"));
}

#[test]
fn bootstrap_service_creates_a_valid_tested_starter_pack() {
    let services = tempfile::tempdir().unwrap();
    let service_dir = services.path().to_str().unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            service_dir,
            "svc",
            "bootstrap",
            "example_service",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Created"));

    let pack = services.path().join("example_service");
    assert!(pack.join("src/init.lua").is_file());
    assert!(pack.join("src/resource.lua").is_file());
    assert!(pack.join("tests/capabilities_test.lua").is_file());
    assert!(pack.join("tests/integration_tests.lua").is_file());
    assert!(pack.join("tests/integraion_guarded_tests.lua").is_file());
    assert!(pack.join("examples/example_service.lua").is_file());
    let skill =
        fs::read_to_string(pack.join(".agents/skills/munray-service-pack/SKILL.md")).unwrap();
    assert!(skill.contains("munray sys list --format markdown"));

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--svc-dir", service_dir, "validate"])
        .assert()
        .success();
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .env("MUNRAY_RUN_GUARDED", "0")
        .args(["--svc-dir", service_dir, "test"])
        .assert()
        .success()
        .stdout(predicate::str::contains("PASS"))
        .stdout(predicate::str::contains("SKIPPED"));

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            service_dir,
            "svc",
            "bootstrap",
            "example_service",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("already exists"));

    fs::write(pack.join("src/init.lua"), "corrupted").unwrap();
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            service_dir,
            "svc",
            "bootstrap",
            "example_service",
            "--force",
        ])
        .assert()
        .success();
    assert!(
        fs::read_to_string(pack.join("src/init.lua"))
            .unwrap()
            .contains("example_service")
    );
}

#[test]
fn bootstrap_update_replaces_the_skill_for_one_or_all_service_packs() {
    let services = tempfile::tempdir().unwrap();
    for name in ["first_service", "second_service"] {
        let pack = services.path().join(name);
        fs::create_dir_all(pack.join("src")).unwrap();
        fs::create_dir_all(pack.join(".agents/skills/munray-service-pack")).unwrap();
        fs::write(
            pack.join(".agents/skills/munray-service-pack/SKILL.md"),
            "outdated",
        )
        .unwrap();
    }
    let service_dir = services.path().to_str().unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--svc-dir", service_dir, "svc", "bootstrap", "--update"])
        .assert()
        .success()
        .stdout(predicate::str::contains("Updated").count(2));
    for name in ["first_service", "second_service"] {
        let skill = fs::read_to_string(
            services
                .path()
                .join(name)
                .join(".agents/skills/munray-service-pack/SKILL.md"),
        )
        .unwrap();
        assert!(skill.contains("Munray service-pack development"));
    }

    fs::write(
        services
            .path()
            .join("first_service/.agents/skills/munray-service-pack/SKILL.md"),
        "outdated again",
    )
    .unwrap();
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            service_dir,
            "svc",
            "bootstrap",
            "first_service",
            "--update",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Updated").count(1));
    assert!(
        fs::read_to_string(
            services
                .path()
                .join("first_service/.agents/skills/munray-service-pack/SKILL.md"),
        )
        .unwrap()
        .contains("Munray service-pack development")
    );
}

#[test]
fn svc_lists_and_uninstalls_service_packs() {
    let services = tempfile::tempdir().unwrap();
    let service_dir = services.path().to_str().unwrap();
    let pack = services.path().join("example_service");
    fs::create_dir_all(pack.join("src")).unwrap();

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["--svc-dir", service_dir, "svc", "list"])
        .assert()
        .success()
        .stdout(predicate::str::contains("example_service"));

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            service_dir,
            "svc",
            "uninstall",
            "example_service",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("pass --force"));
    assert!(pack.exists());

    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            service_dir,
            "svc",
            "uninstall",
            "example_service",
            "--force",
        ])
        .assert()
        .success()
        .stdout(predicate::str::contains("Removed"));
    assert!(!pack.exists());
}

#[test]
fn bootstrap_service_rejects_non_lua_service_names() {
    let services = tempfile::tempdir().unwrap();
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args([
            "--svc-dir",
            services.path().to_str().unwrap(),
            "svc",
            "bootstrap",
            "not-valid",
        ])
        .assert()
        .failure()
        .stderr(predicate::str::contains("invalid service name"));
}

#[test]
fn list_sys_renders_documented_primitives_in_text() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["sys", "list", "--format", "text"])
        .assert()
        .success()
        .stdout(predicate::str::contains("sys.http\n    HTTP requests"))
        .stdout(predicate::str::contains(
            "    request(method string, base_url string, path string, opts? table) -> table",
        ))
        .stdout(predicate::str::contains(
            "sys.graphql\n    GraphQL requests",
        ))
        .stdout(predicate::str::contains(
            "    start_request(base_url string, document string, opts? table) -> task_id",
        ))
        .stdout(predicate::str::contains(
            "sys.kv\n    Durable key-value storage",
        ))
        .stdout(predicate::str::contains(
            "    put(namespace string, key string, value any, opts? table) -> boolean",
        ))
        .stdout(predicate::str::contains(
            "sys.snippets\n    Persisted snippets",
        ));
}

#[test]
fn list_sys_defaults_to_text() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["sys", "list"])
        .assert()
        .success()
        .stdout(predicate::str::starts_with("sys\n    Runtime helpers\n"))
        .stdout(predicate::str::contains("    exec_mode() -> string\n"));
}

#[test]
fn list_sys_can_render_markdown() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["sys", "list", "--format", "markdown"])
        .assert()
        .success()
        .stdout(predicate::str::starts_with("## `sys` — Runtime helpers\n"))
        .stdout(predicate::str::contains("| Function | Description |"));
}

#[test]
fn sys_metadata_matches_reflected_primitives() {
    let runtime = LuaRuntime::new(None).unwrap();
    let reflected = runtime.list_sys_primitives().unwrap();
    assert!(
        sys_catalog::undocumented_paths(&reflected).is_empty(),
        "reflected primitives missing metadata: {:?}",
        sys_catalog::undocumented_paths(&reflected)
    );
    assert!(
        sys_catalog::stale_paths(&reflected).is_empty(),
        "metadata without a reflected primitive: {:?}",
        sys_catalog::stale_paths(&reflected)
    );
}

#[test]
fn list_sys_json_is_machine_readable() {
    Command::cargo_bin(env!("CARGO_PKG_NAME"))
        .unwrap()
        .args(["sys", "list", "--format", "json"])
        .assert()
        .success()
        .stdout(predicate::str::contains("\"version\": 1"))
        .stdout(predicate::str::contains("\"path\": \"sys.http\""))
        .stdout(predicate::str::contains("\"path\": \"sys.http.request\""));
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
