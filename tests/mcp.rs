use assert_cmd::{Command, cargo::cargo_bin};
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    process::{ChildStdin, ChildStdout, Command as ProcessCommand, Stdio},
    time::{Duration, Instant},
};

fn line(value: Value) -> String {
    format!("{}\n", serde_json::to_string(&value).unwrap())
}

fn exchange(stdin: &mut ChildStdin, stdout: &mut BufReader<ChildStdout>, value: Value) -> Value {
    stdin.write_all(line(value).as_bytes()).unwrap();
    stdin.flush().unwrap();
    let mut response = String::new();
    stdout.read_line(&mut response).unwrap();
    serde_json::from_str(&response).unwrap()
}

#[test]
fn mcp_initializes_lists_tools_and_reuses_session_state() {
    let mut child = ProcessCommand::new(cargo_bin("luaris-mcp"))
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut request = |value: Value| {
        stdin.write_all(line(value).as_bytes()).unwrap();
        stdin.flush().unwrap();
        let mut response = String::new();
        stdout.read_line(&mut response).unwrap();
        serde_json::from_str::<Value>(&response).unwrap()
    };
    let initialized = request(
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
    );
    assert_eq!(initialized["result"]["serverInfo"]["name"], "luaris-mcp");
    let listed = request(json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}));
    assert_eq!(listed["result"]["tools"].as_array().unwrap().len(), 2);
    request(
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"answer = 41; return answer","session_id":"same"}}}),
    );
    let response = request(
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"answer = answer + 1; return answer","session_id":"same"}}}),
    );
    let payload: Value =
        serde_json::from_str(response["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["session_id"], "same");
    assert_eq!(payload["result"], 42);
    let context_response = request(
        json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"return capabilities.ai_context().runtime.server_id","session_id":"same"}}}),
    );
    let context_payload: Value = serde_json::from_str(
        context_response["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        context_payload["result"],
        serde_json::json!(child.id().to_string())
    );
    drop(stdin);
    assert!(child.wait().unwrap().success());
}

#[test]
fn mutating_tool_requires_elicitation_before_execution_and_honors_the_decision() {
    let mut child = ProcessCommand::new(cargo_bin("luaris-mcp"))
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());

    exchange(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{"elicitation":{"form":{}}},"clientInfo":{"name":"test","version":"1"}}}),
    );
    stdin
        .write_all(
            line(json!({"jsonrpc":"2.0","method":"notifications/initialized","params":{}}))
                .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();
    stdin
        .write_all(
            line(json!({
                "jsonrpc":"2.0", "id":2, "method":"tools/call",
                "params":{"name":"lua_runMutatingLuaScript","arguments":{
                    "code":"_G.mutating_test_value = 42; return true",
                    "session_id":"elicitation-test"
                }}
            }))
            .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();

    let mut elicitation_line = String::new();
    stdout.read_line(&mut elicitation_line).unwrap();
    let elicitation: Value = serde_json::from_str(&elicitation_line).unwrap();
    assert_eq!(
        elicitation["method"], "elicitation/create",
        "unexpected server message: {elicitation}"
    );
    assert!(
        elicitation["params"]["message"]
            .as_str()
            .unwrap()
            .contains("mutating_test_value")
    );
    stdin
        .write_all(
            line(json!({
                "jsonrpc":"2.0",
                "id":elicitation["id"].clone(),
                "result":{"action":"accept","content":{"decision":"Reject"}}
            }))
            .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();

    let mut rejected_line = String::new();
    stdout.read_line(&mut rejected_line).unwrap();
    let rejected: Value = serde_json::from_str(&rejected_line).unwrap();
    let payload: Value =
        serde_json::from_str(rejected["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["error"]["code"], "MUTATING_REJECTED");

    let read = exchange(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc":"2.0", "id":3, "method":"tools/call",
            "params":{"name":"lua_runLuaScript","arguments":{
                "code":"return _G.mutating_test_value",
                "session_id":"elicitation-test"
            }}
        }),
    );
    let read_payload: Value =
        serde_json::from_str(read["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(read_payload["result"], Value::Null);

    stdin
        .write_all(
            line(json!({
                "jsonrpc":"2.0", "id":4, "method":"tools/call",
                "params":{"name":"lua_runMutatingLuaScript","arguments":{
                    "code":"_G.mutating_test_value = 42; return _G.mutating_test_value",
                    "session_id":"elicitation-test"
                }}
            }))
            .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();
    let mut approval_line = String::new();
    stdout.read_line(&mut approval_line).unwrap();
    let approval: Value = serde_json::from_str(&approval_line).unwrap();
    assert_eq!(approval["method"], "elicitation/create");
    stdin
        .write_all(
            line(json!({
                "jsonrpc":"2.0",
                "id":approval["id"].clone(),
                "result":{"action":"accept","content":{"decision":"Approve"}}
            }))
            .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();
    let mut approved_line = String::new();
    stdout.read_line(&mut approved_line).unwrap();
    let approved: Value = serde_json::from_str(&approved_line).unwrap();
    let approved_payload: Value =
        serde_json::from_str(approved["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(approved_payload["result"], 42);

    drop(stdin);
    assert!(child.wait().unwrap().success());
}

#[test]
fn mutating_tool_without_form_elicitation_capability_uses_source_fallback() {
    let input = [
        line(json!({
            "jsonrpc":"2.0", "id":1, "method":"initialize",
            "params":{
                "protocolVersion":"2025-11-25",
                "capabilities":{},
                "clientInfo":{"name":"test","version":"1"}
            }
        })),
        line(json!({
            "jsonrpc":"2.0", "id":2, "method":"tools/call",
            "params":{"name":"lua_runMutatingLuaScript","arguments":{
                "code":"_G.fallback_mutation = 42; return _G.fallback_mutation",
                "session_id":"fallback-test"
            }}
        })),
    ]
    .concat();

    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .arg("mcp")
        .write_stdin(input)
        .assert()
        .success()
        .stdout(predicates::str::contains("fallback-test"))
        .stdout(predicates::str::contains("42"));
}

#[test]
fn mcp_rejects_raw_calls_outside_schema_context() {
    let input = [
        line(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}})),
        line(json!({
            "jsonrpc":"2.0", "id":2, "method":"tools/call",
            "params":{"name":"lua_runLuaScript","arguments":{"code":"local value, err = _raw.exec_mode(); return err.code"}}
        })),
    ].concat();
    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .arg("mcp")
        .write_stdin(input)
        .assert()
        .success()
        .stdout(predicates::str::contains("RAW_OUTSIDE_SCHEMA"));
}

#[test]
fn schema_backed_core_function_can_enter_raw_context() {
    let input = [
        line(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}})),
        line(json!({
            "jsonrpc":"2.0", "id":2, "method":"tools/call",
            "params":{"name":"lua_runLuaScript","arguments":{"code":"local ok, err = vfs.write_text('proof.txt', 'ok'); if err then return err.code end; return ok"}}
        })),
    ]
    .concat();
    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .arg("mcp")
        .write_stdin(input)
        .assert()
        .success()
        .stdout(predicates::str::contains("proof.txt"));
}

#[test]
fn mcp_preserves_printed_output_when_lua_fails() {
    let input = [
        line(json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}})),
        line(json!({
            "jsonrpc":"2.0", "id":2, "method":"tools/call",
            "params":{"name":"lua_runLuaScript","arguments":{"code":"print('before failure'); error('boom')","session_id":"failure-output"}}
        })),
    ]
    .concat();
    Command::cargo_bin("luaris-mcp")
        .unwrap()
        .arg("mcp")
        .write_stdin(input)
        .assert()
        .success()
        .stdout(predicates::str::contains("before failure"))
        .stdout(predicates::str::contains("boom"));
}

#[test]
fn independent_sessions_overlap_and_reused_session_is_fifo() {
    let services = tempfile::tempdir().unwrap();
    let src = services.path().join("demo/src");
    fs::create_dir_all(&src).unwrap();
    fs::write(
        src.join("init.lua"),
        r#"
local raw_text = _raw.cli.text
demo = {
  __allowed_cli_commands = {"sh"},
  __schema = {namespace="demo",service="demo",functions={{name="pause",mutating=false,returns_contract="core.result"}}}
}
function demo.pause()
  local _, err = raw_text("sh", {"-c", "sleep 0.25"})
  if err then return nil, err end
  return true, nil
end
"#,
    )
    .unwrap();
    let mut child = ProcessCommand::new(cargo_bin("luaris-mcp"))
        .args(["--svc-dir", services.path().to_str().unwrap(), "mcp"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    exchange(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
    );

    let started = Instant::now();
    stdin
        .write_all(
            [
                line(json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"return demo.pause()","session_id":"parallel-a"}}})),
                line(json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"return demo.pause()","session_id":"parallel-b"}}})),
            ]
            .concat()
            .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();
    for _ in 0..2 {
        let mut response = String::new();
        stdout.read_line(&mut response).unwrap();
    }
    assert!(started.elapsed() < Duration::from_millis(450));

    stdin
        .write_all(
            [
                line(json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"demo.pause(); ordered = 42; return ordered","session_id":"fifo"}}})),
                line(json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"return ordered","session_id":"fifo"}}})),
            ]
            .concat()
            .as_bytes(),
        )
        .unwrap();
    stdin.flush().unwrap();
    let mut payloads = std::collections::HashMap::new();
    for _ in 0..2 {
        let mut response = String::new();
        stdout.read_line(&mut response).unwrap();
        let response: Value = serde_json::from_str(&response).unwrap();
        let payload: Value =
            serde_json::from_str(response["result"]["content"][0]["text"].as_str().unwrap())
                .unwrap();
        payloads.insert(response["id"].as_i64().unwrap(), payload);
    }
    assert_eq!(payloads[&5]["result"], 42);
    drop(stdin);
    assert!(child.wait().unwrap().success());
}

#[cfg(unix)]
#[test]
#[ignore = "requires Unix socket permissions unavailable in the managed sandbox"]
fn cli_ingest_targets_an_existing_mcp_session() {
    let mut child = ProcessCommand::new(cargo_bin("luaris-mcp"))
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let server_id = child.id().to_string();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    exchange(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
    );
    exchange(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":"return true","session_id":"ingest-session"}}}),
    );

    let output = Command::cargo_bin("luaris-mcp")
        .unwrap()
        .args([
            "ingest",
            "--server",
            &server_id,
            "--session",
            "ingest-session",
            "--json",
        ])
        .write_stdin("piped text")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let ingest: Value = serde_json::from_slice(&output.stdout).unwrap();
    let token = ingest["token"].as_str().unwrap();

    let response = exchange(
        &mut stdin,
        &mut stdout,
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"lua_runLuaScript","arguments":{"code":format!("return ingest.get('{token}')"),"session_id":"ingest-session"}}}),
    );
    let payload: Value =
        serde_json::from_str(response["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["result"], "piped text");
    drop(stdin);
    assert!(child.wait().unwrap().success());
}
