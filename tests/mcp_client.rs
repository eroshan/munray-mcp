#![cfg(feature = "mcp-client")]

use assert_cmd::cargo::cargo_bin;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use mcp_server::runtime::{ExecutionMode, LuaRuntime};
use reqwest::Url;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs,
    io::{BufRead, BufReader, Read, Write},
    net::{TcpListener, TcpStream},
    path::Path,
    process::{Child, Command, Output, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};

const WAIT: Duration = Duration::from_secs(10);

struct Request {
    method: String,
    target: String,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

impl Request {
    fn read(stream: &TcpStream) -> std::io::Result<Self> {
        stream.set_read_timeout(Some(WAIT))?;
        let mut input = BufReader::new(stream);
        let mut line = String::new();
        input.read_line(&mut line)?;
        let mut fields = line.split_whitespace();
        let method = fields.next().unwrap_or_default().to_owned();
        let target = fields.next().unwrap_or_default().to_owned();
        let mut headers = HashMap::new();
        loop {
            line.clear();
            if input.read_line(&mut line)? == 0 || line == "\r\n" {
                break;
            }
            if let Some((name, value)) = line.split_once(':') {
                headers.insert(name.to_ascii_lowercase(), value.trim().to_owned());
            }
        }
        let mut body = vec![
            0;
            headers
                .get("content-length")
                .map_or(0, |value| value.parse().unwrap())
        ];
        input.read_exact(&mut body)?;
        Ok(Self {
            method,
            target,
            headers,
            body,
        })
    }

    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap()
    }

    fn auth(&self) -> Option<&str> {
        self.headers.get("authorization").map(String::as_str)
    }
}

struct Server {
    url: String,
    stopped: Arc<AtomicBool>,
    accept: Option<thread::JoinHandle<()>>,
}

impl Server {
    fn new(handler: impl Fn(TcpStream, Request, &str) + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        listener.set_nonblocking(true).unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let origin = url.clone();
        let stopped = Arc::new(AtomicBool::new(false));
        let stop = Arc::clone(&stopped);
        let handler = Arc::new(handler);
        let accept = thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let origin = origin.clone();
                        let handler = Arc::clone(&handler);
                        thread::spawn(move || {
                            if let Ok(request) = Request::read(&stream)
                                && !request.method.is_empty()
                            {
                                handler(stream, request, &origin);
                            }
                        });
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("MCP test server accept failed: {error}"),
                }
            }
        });
        Self {
            url,
            stopped,
            accept: Some(accept),
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Relaxed);
        self.accept.take().unwrap().join().unwrap();
    }
}

fn respond(mut stream: TcpStream, status: &str, headers: &[(&str, &str)], body: &str) {
    write!(
        stream,
        "HTTP/1.1 {status}\r\nConnection: close\r\nContent-Length: {}\r\n",
        body.len()
    )
    .unwrap();
    for (key, value) in headers {
        write!(stream, "{key}: {value}\r\n").unwrap();
    }
    write!(stream, "\r\n{body}").unwrap();
}

fn respond_json(stream: TcpStream, value: &Value) {
    respond(
        stream,
        "200 OK",
        &[("Content-Type", "application/json")],
        &value.to_string(),
    );
}

type LegacyEvents = Mutex<Option<mpsc::Sender<String>>>;

fn start_legacy_stream(mut stream: TcpStream, endpoint: &str, events: &LegacyEvents) {
    let (send, receive) = mpsc::channel();
    *events.lock().unwrap() = Some(send);
    write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\nevent: endpoint\ndata: {endpoint}\n\n").unwrap();
    while let Ok(event) = receive.recv_timeout(WAIT) {
        if writeln!(stream, "event: message\ndata: {event}\n").is_err() {
            break;
        }
    }
}

fn respond_rpc(stream: TcpStream, result: Option<Value>, events: Option<&LegacyEvents>) {
    match (result, events) {
        (Some(result), None) => respond_json(stream, &result),
        (Some(result), Some(events)) => {
            events
                .lock()
                .unwrap()
                .as_ref()
                .unwrap()
                .send(result.to_string())
                .unwrap();
            respond(stream, "202 Accepted", &[], "");
        }
        (None, _) => respond(stream, "202 Accepted", &[], ""),
    }
}

fn reply(request: &Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":request["id"],"result":result})
}

fn initialize(request: &Value) -> Value {
    reply(
        request,
        json!({
            "protocolVersion": request["params"]["protocolVersion"],
            "capabilities": {"tools":{}},
            "serverInfo": {"name":"test-server","version":"1"},
        }),
    )
}

fn tool(name: &str, description: &str) -> Value {
    json!({
        "name":name, "description":description,
        "inputSchema":{"type":"object","properties":{"room":{"type":"string"}},"required":["room"]},
        "outputSchema":{"type":"object","properties":{"room":{"type":"string"}}},
    })
}

fn command(services: &Path) -> Command {
    let mut command = command_with_default_store(services);
    command.arg("--store-path").arg(services.join("test.db"));
    command
}

fn command_with_default_store(services: &Path) -> Command {
    let mut command = Command::new(cargo_bin(env!("CARGO_PKG_NAME")));
    command
        .args(["--svc-dir"])
        .arg(services)
        .env("NO_PROXY", "127.0.0.1,localhost")
        .env("no_proxy", "127.0.0.1,localhost");
    command
}

fn assert_success(output: Output) -> String {
    assert!(
        output.status.success(),
        "Munray failed\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

fn run(runtime: &LuaRuntime, code: &str) -> Value {
    let result = runtime
        .execute(code, ExecutionMode::ReadOnly, "remote MCP test")
        .unwrap();
    result.result
}

#[test]
fn bootstrap_rejects_occupied_lua_namespaces_before_scanning() {
    let services = tempfile::tempdir().unwrap();
    let existing = services.path().join("existing/src");
    fs::create_dir_all(&existing).unwrap();
    fs::write(existing.join("init.lua"), "other_namespace = {}").unwrap();

    for (name, detail) in [
        ("json", "conflicts with a built-in Lua global"),
        ("sys", "conflicts with a built-in Lua global"),
        ("print", "conflicts with a built-in Lua global"),
        ("other_namespace", "is already used by an installed service"),
    ] {
        let output = command(services.path())
            .args(["svc", "bootstrap", name, "--mcp-url", "invalid-url"])
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(!output.status.success());
        assert!(
            stderr.contains(&format!("MCP pack namespace {name:?} {detail}")),
            "{stderr}"
        );
        assert!(!services.path().join(name).exists());
    }
}

#[test]
#[ignore = "requires loopback TCP permissions unavailable in the managed sandbox"]
fn imports_paginated_tools_and_refreshes_schema_without_changing_policy() {
    let calls = Arc::new(AtomicUsize::new(0));
    let recorded_calls = Arc::clone(&calls);
    let changed = Arc::new(AtomicBool::new(false));
    let updated = Arc::clone(&changed);
    let server = Server::new(move |stream, request, _| {
        if updated.load(Ordering::Relaxed) {
            assert_eq!(request.target, "/updated");
        }
        let rpc = request.json();
        match rpc["method"].as_str().unwrap() {
            "initialize" => respond_json(stream, &initialize(&rpc)),
            "notifications/initialized" => respond(stream, "202 Accepted", &[], ""),
            "tools/list" if rpc["params"]["cursor"] == "second" => {
                let more = if updated.load(Ordering::Relaxed) {
                    vec![tool("new", "new tool")]
                } else {
                    vec![
                        tool("play", "guarded playback"),
                        tool("hide", "hidden on refresh"),
                    ]
                };
                respond_json(stream, &reply(&rpc, json!({"tools":more})));
            }
            "tools/list" => {
                let description = if updated.load(Ordering::Relaxed) {
                    "updated description"
                } else {
                    "room query"
                };
                respond_json(
                    stream,
                    &reply(
                        &rpc,
                        json!({"tools":[tool("get-room", description)], "nextCursor":"second"}),
                    ),
                );
            }
            "tools/call" => {
                recorded_calls.fetch_add(1, Ordering::Relaxed);
                respond_json(
                    stream,
                    &reply(
                        &rpc,
                        json!({
                            "content": [{"type":"text","text":"ok"}],
                            "structuredContent":{"room":rpc["params"]["arguments"]["room"],"tool":rpc["params"]["name"]},
                        }),
                    ),
                );
            }
            method => panic!("unsupported method {method}"),
        }
    });
    let temp = tempfile::tempdir().unwrap();
    let config = temp.path().join("servers.json");
    fs::write(
        &config,
        json!({"mcpServers":{"test":{"url":format!("{}/mcp", server.url)}}}).to_string(),
    )
    .unwrap();
    assert_success(
        command(temp.path())
            .args(["svc", "bootstrap", "remote", "--config"])
            .arg(&config)
            .args(["--server", "test"])
            .output()
            .unwrap(),
    );

    assert_success(
        command(temp.path())
            .args(["svc", "validate", "remote"])
            .output()
            .unwrap(),
    );
    let runtime = LuaRuntime::new_session(Some(temp.path())).unwrap();
    assert_eq!(
        run(&runtime, "local _, err = remote.play({}); return err.code"),
        "GUARDED_TOOL_REQUIRED"
    );
    assert_eq!(calls.load(Ordering::Relaxed), 0);
    assert_eq!(
        run(
            &runtime,
            r#"return schema("remote").functions[1].input_schema.properties.room.type"#
        ),
        "string"
    );
    let mut guarded = command(temp.path());
    let mut child = guarded
        .args(["mcp", "--delegate-guarded-approval-to-harness"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test-harness","version":"1"}
        }}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"runGuardedLuaScript","arguments":{
                "code":"local result, err = remote.play({room='Office'}); assert(result, err and err.message); return result.structuredContent.tool"
            }
        }}),
    ] {
        writeln!(input, "{message}").unwrap();
    }
    input.flush().unwrap();
    let response: Value = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map_while(Result::ok)
        .filter_map(|line| serde_json::from_str::<Value>(&line).ok())
        .find(|response| response["id"] == 2)
        .unwrap();
    drop(input);
    assert_success(child.wait_with_output().unwrap());
    let payload: Value =
        serde_json::from_str(response["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(payload["result"], "play");
    assert_eq!(calls.load(Ordering::Relaxed), 1);

    let policy = temp.path().join("remote/config.lua");
    let original = fs::read_to_string(&policy).unwrap();
    assert!(original.contains(&format!(r#"url = "{}/mcp""#, server.url)));
    assert!(original.contains("play = { enabled = true, guarded = true }"));
    assert!(original.contains(r#"["get-room"] = { enabled = true, guarded = true }"#));
    let catalog: Value =
        serde_json::from_slice(&fs::read(temp.path().join("remote/mcp-catalog.json")).unwrap())
            .unwrap();
    assert!(catalog.get("connection").is_none());
    let edited = format!(
        r#"assert(sys.exec_mode() == "readonly")
           local connection = json.decode(' {{"url":"{}/updated"}} ')
           return {{ connection = connection, tools = {{ ["get-room"] = {{ enabled = true, guarded = false }}, play = {{ enabled = false }} }} }}"#,
        server.url
    );
    fs::write(&policy, &edited).unwrap();
    let runtime = LuaRuntime::new_session(Some(temp.path())).unwrap();
    assert_eq!(
        run(
            &runtime,
            r#"return { remote.play == nil, remote.hide == nil, #schema("remote").functions }"#
        ),
        json!([true, true, 1])
    );
    assert_eq!(
        run(
            &runtime,
            r#"local result, err = remote.get_room({room = "Office"}); assert(result, err and err.message); return result.structuredContent"#
        ),
        json!({"tool":"get-room","room":"Office"})
    );
    assert_eq!(
        run(
            &runtime,
            "local args = {}; args.self = args; local _, err = remote.get_room(args); return err.code"
        ),
        "MCP_ARGUMENTS"
    );
    assert_eq!(calls.load(Ordering::Relaxed), 2);
    let entrypoint = temp.path().join("remote/src/init.lua");
    let customized = format!(
        "-- Local customization\n{}",
        fs::read_to_string(&entrypoint).unwrap()
    );
    fs::write(&entrypoint, &customized).unwrap();
    changed.store(true, Ordering::Relaxed);
    let report = assert_success(
        command(temp.path())
            .args(["svc", "refresh", "remote"])
            .output()
            .unwrap(),
    );
    assert!(report.contains("Added \"new\""));
    assert_eq!(fs::read_to_string(&policy).unwrap(), edited);
    assert_eq!(fs::read_to_string(&entrypoint).unwrap(), customized);
    let runtime = LuaRuntime::new_session(Some(temp.path())).unwrap();
    assert_eq!(
        run(
            &runtime,
            r#"return { schema("remote").functions[1].description, remote.play == nil, remote.new == nil }"#
        ),
        json!(["updated description", true, true])
    );

    let connection = json!({"url": format!("{}/updated", server.url)});
    let data_home = temp.path().join("data");
    let explicit_store = temp.path().join("test.db");
    let default_store = data_home.join("store.db");
    for path in [&explicit_store, &default_store] {
        mcp_server::storage::Store::open(Some(path))
            .unwrap()
            .put_kv(
                "remote",
                "connection",
                &connection,
                "application/json",
                None,
                None,
            )
            .unwrap();
    }
    fs::write(
        &policy,
        r#"
        local connection = kv.get("remote", "connection")
        assert(connection, "missing persisted MCP connection")
        return { connection = connection, tools = {} }
    "#,
    )
    .unwrap();
    for mut refresh in [
        command(temp.path()),
        {
            let mut cmd = command_with_default_store(temp.path());
            cmd.env("MUNRAY_MCP_STORE_PATH", &explicit_store);
            cmd
        },
        {
            let mut cmd = command_with_default_store(temp.path());
            cmd.env_remove("MUNRAY_MCP_STORE_PATH")
                .env("MUNRAY_MCP_HOME", &data_home);
            cmd
        },
    ] {
        assert_success(refresh.args(["svc", "refresh", "remote"]).output().unwrap());
    }

    let endpoint = format!("{}/updated", server.url);
    let mut default_bootstrap = command_with_default_store(temp.path());
    default_bootstrap
        .env_remove("MUNRAY_MCP_STORE_PATH")
        .env("MUNRAY_MCP_HOME", &data_home);
    for (mut bootstrap, name) in [
        (command(temp.path()), "explicit_store_pack"),
        (default_bootstrap, "default_store_pack"),
    ] {
        assert_success(
            bootstrap
                .args(["svc", "bootstrap", name, "--mcp-url", &endpoint])
                .output()
                .unwrap(),
        );
        assert!(temp.path().join(name).join("src/init.lua").is_file());
    }

    let manual = LuaRuntime::new(None).unwrap();
    assert_eq!(
        run(
            &manual,
            &format!(
                r#"local auth, err = sys.mcp.auth({{url = "{}/updated"}})
                   assert(auth, err and err.message)
                   local result, err = sys.mcp.tool_call(auth, "get-room", {{room = "Office"}})
                   assert(result, err and err.message)
                   return result.structuredContent"#,
                server.url
            ),
        ),
        json!({"tool":"get-room","room":"Office"})
    );

    let pack = temp.path().join("remote");
    let mut old_catalog = catalog;
    old_catalog["version"] = json!(1);
    old_catalog["connection"] = json!({"url":format!("{}/updated", server.url)});
    fs::write(pack.join("mcp-catalog.json"), old_catalog.to_string()).unwrap();
    fs::write(
        &policy,
        r#"return { ["get-room"] = { enabled = true, guarded = false } }"#,
    )
    .unwrap();
    fs::write(
        pack.join("src/init.lua"),
        r#"
        local namespace, directory = ...
        local ok, err = sys.mcp.load(namespace, directory)
        assert(ok, err and err.message)
    "#,
    )
    .unwrap();
    let legacy = LuaRuntime::new_session(Some(temp.path())).unwrap();
    assert_eq!(
        run(&legacy, r#"return schema("remote").functions[1].name"#),
        "get_room"
    );
}

#[test]
#[ignore = "requires loopback TCP permissions unavailable in the managed sandbox"]
fn legacy_sse_posts_authenticated_requests_and_rejects_cross_origin_messages() {
    let events = Arc::new(LegacyEvents::default());
    let target = Arc::new(Mutex::new(None::<String>));
    let advertised = Arc::clone(&target);
    let network = Arc::clone(&events);
    let server = Server::new(move |stream, request, _| {
        assert_eq!(request.auth(), Some("Bearer sse-token"));
        if request.method == "GET" {
            let endpoint = advertised
                .lock()
                .unwrap()
                .clone()
                .unwrap_or_else(|| "/messages?session=1".to_owned());
            start_legacy_stream(stream, &endpoint, &network);
        } else {
            assert_eq!(request.target, "/messages?session=1");
            let rpc = request.json();
            let result = match rpc["method"].as_str().unwrap() {
                "initialize" => Some(initialize(&rpc)),
                "notifications/initialized" => None,
                "tools/list" => Some(reply(&rpc, json!({"tools":[tool("read","read")]}))),
                "tools/call" => Some(reply(
                    &rpc,
                    json!({"content":[{"type":"text","text":"via SSE"}]}),
                )),
                method => panic!("unsupported method {method}"),
            };
            respond_rpc(stream, result, Some(&network));
        }
    });
    let temp = tempfile::tempdir().unwrap();
    let endpoint = format!("{}/sse", server.url);
    let mut bootstrap = command(temp.path());
    bootstrap.env("MUNRAY_TEST_SSE_TOKEN", "sse-token").args([
        "svc",
        "bootstrap",
        "legacy",
        "--mcp-url",
        &endpoint,
        "--transport",
        "sse",
        "--token-env",
        "MUNRAY_TEST_SSE_TOKEN",
    ]);
    assert_success(bootstrap.output().unwrap());
    let output = assert_success(command(temp.path()).env("MUNRAY_TEST_SSE_TOKEN", "sse-token")
        .arg("run").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped())
        .spawn().and_then(|mut child| {
            child.stdin.take().unwrap().write_all(b"local result, err = legacy.read(); assert(result, err and err.message); return result.content[1].text")?;
            child.wait_with_output()
        }).unwrap());
    assert!(output.contains("via SSE"));

    let unexpected = Arc::new(AtomicUsize::new(0));
    let requests = Arc::clone(&unexpected);
    let other = Server::new(move |stream, _, _| {
        requests.fetch_add(1, Ordering::Relaxed);
        respond(stream, "202 Accepted", &[], "");
    });
    *target.lock().unwrap() = Some(format!("{}/receives-nothing", other.url));
    let output = command(temp.path())
        .env("MUNRAY_TEST_SSE_TOKEN", "sse-token")
        .args([
            "svc",
            "bootstrap",
            "unsafe_endpoint",
            "--mcp-url",
            &endpoint,
            "--transport",
            "sse",
            "--token-env",
            "MUNRAY_TEST_SSE_TOKEN",
            "--timeout",
            "3",
        ])
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(unexpected.load(Ordering::Relaxed), 0);
    assert!(!temp.path().join("unsafe_endpoint").exists());
}

struct BrowserCommand {
    child: Option<Child>,
    stderr: mpsc::Receiver<String>,
}

impl BrowserCommand {
    fn start(mut command: Command) -> Self {
        let mut child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let output = child.stderr.take().unwrap();
        let (send, stderr) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::new(output).lines().map_while(Result::ok) {
                let _ = send.send(line);
            }
        });
        Self {
            child: Some(child),
            stderr,
        }
    }

    fn authorize(&self) {
        let reminder = self.stderr.recv_timeout(WAIT).unwrap();
        assert!(
            reminder.contains("Authorize the MCP integration"),
            "{reminder}"
        );
        let authorization = self.stderr.recv_timeout(WAIT).unwrap();
        let client = reqwest::blocking::Client::builder()
            .no_proxy()
            .timeout(WAIT)
            .build()
            .unwrap();
        assert!(
            client
                .get(authorization)
                .send()
                .unwrap()
                .status()
                .is_success()
        );
    }

    fn finish(mut self) -> String {
        let output = self.child.take().unwrap().wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "OAuth Munray failure: {:?}",
            self.stderr.try_iter().collect::<Vec<_>>()
        );
        assert_success(output)
    }

    fn expect_failure(mut self, message: &str) {
        let output = self.child.take().unwrap().wait_with_output().unwrap();
        assert!(!output.status.success());
        let diagnostics: Vec<_> = self.stderr.iter().collect();
        assert!(
            diagnostics.iter().any(|line| line.contains(message)),
            "{diagnostics:?}"
        );
    }
}

impl Drop for BrowserCommand {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn parameters(target: &str) -> HashMap<String, String> {
    Url::parse(&format!("http://localhost/{target}"))
        .unwrap()
        .query_pairs()
        .into_owned()
        .collect()
}

#[test]
#[ignore = "requires loopback TCP permissions unavailable in the managed sandbox"]
fn oauth_registers_refreshes_upgrades_scope_and_reopens_browser() {
    enum RejectedResource {
        Unrelated,
        Null,
        Missing,
        DotSegments,
    }

    for (preregistered, rejected_resource) in [
        (false, None),
        (true, None),
        (true, Some(RejectedResource::Unrelated)),
        (true, Some(RejectedResource::Null)),
        (true, Some(RejectedResource::Missing)),
        (true, Some(RejectedResource::DotSegments)),
    ] {
        let root_fallback = rejected_resource.is_some();
        let events = (!preregistered).then(LegacyEvents::default);
        let registrations = Arc::new(AtomicUsize::new(0));
        let recorded_registrations = Arc::clone(&registrations);
        let authorizations = Arc::new(AtomicUsize::new(0));
        let recorded_authorizations = Arc::clone(&authorizations);
        let refreshes = Arc::new(AtomicUsize::new(0));
        let recorded_refreshes = Arc::clone(&refreshes);
        let proofs = Arc::new(Mutex::new(HashMap::new()));
        let deny_extra_scope = Arc::new(AtomicBool::new(false));
        let deny_scope = Arc::clone(&deny_extra_scope);
        let rejected_issuer_requests = Arc::new(AtomicUsize::new(0));
        let issuer_requests = Arc::clone(&rejected_issuer_requests);
        let server = Server::new(move |stream, request, origin| {
            if request.target.contains("unexpected-issuer") {
                issuer_requests.fetch_add(1, Ordering::Relaxed);
                respond(stream, "404 Not Found", &[], "");
                return;
            }
            let oauth_resource = if root_fallback {
                origin.to_owned()
            } else {
                format!("{origin}/mcp")
            };
            match request.target.split('?').next().unwrap() {
                "/mcp" | "/messages" => {
                    if !request
                        .auth()
                        .is_some_and(|auth| auth.starts_with("Bearer token-"))
                    {
                        let metadata = if root_fallback {
                            "/.well-known/oauth-protected-resource"
                        } else {
                            "/protected"
                        };
                        let challenge = format!("Bearer resource_metadata=\"{origin}{metadata}\"");
                        respond(
                            stream,
                            "401 Unauthorized",
                            &[("WWW-Authenticate", &challenge)],
                            "",
                        );
                        return;
                    }
                    if request.method == "GET" {
                        start_legacy_stream(stream, "/messages", events.as_ref().unwrap());
                        return;
                    }
                    let rpc = request.json();
                    if deny_scope.load(Ordering::Relaxed) && rpc["method"] == "tools/list" {
                        respond(
                            stream,
                            "403 Forbidden",
                            &[(
                                "WWW-Authenticate",
                                r#"Bearer error="insufficient_scope", scope="admin""#,
                            )],
                            "",
                        );
                        return;
                    }
                    if preregistered
                        && rpc["method"] == "tools/list"
                        && request.auth() == Some("Bearer token-code-1")
                    {
                        respond(
                            stream,
                            "403 Forbidden",
                            &[(
                                "WWW-Authenticate",
                                r#"Bearer error="insufficient_scope", scope="queue""#,
                            )],
                            "",
                        );
                        return;
                    }
                    let result = match rpc["method"].as_str().unwrap() {
                        "initialize" => Some(initialize(&rpc)),
                        "notifications/initialized" => None,
                        "tools/list" => {
                            Some(reply(&rpc, json!({"tools":[tool("read","OAuth read")]})))
                        }
                        "tools/call" => {
                            let version = request
                                .auth()
                                .unwrap()
                                .strip_prefix("Bearer token-")
                                .unwrap();
                            Some(reply(
                                &rpc,
                                json!({"content":[{"type":"text","text":version}]}),
                            ))
                        }
                        method => panic!("unsupported method {method}"),
                    };
                    respond_rpc(stream, result, events.as_ref());
                }
                "/protected" => respond_json(
                    stream,
                    &json!({"resource":format!("{origin}/mcp"),"authorization_servers":[origin],"scopes_supported":["read"]}),
                ),
                "/.well-known/oauth-protected-resource/mcp" if root_fallback => {
                    let mut metadata =
                        json!({"authorization_servers": [format!("{origin}/unexpected-issuer")]});
                    match rejected_resource.as_ref().unwrap() {
                        RejectedResource::Unrelated => {
                            metadata["resource"] = json!("https://unrelated.example/mcp")
                        }
                        RejectedResource::Null => metadata["resource"] = Value::Null,
                        RejectedResource::Missing => (),
                        RejectedResource::DotSegments => {
                            metadata["resource"] = json!(format!("{origin}/noncanonical/../mcp"))
                        }
                    }
                    respond_json(stream, &metadata);
                }
                "/.well-known/oauth-protected-resource" if root_fallback => respond_json(
                    stream,
                    &json!({"resource":origin,"authorization_servers":[origin],"scopes_supported":["read"]}),
                ),
                "/.well-known/oauth-authorization-server" => respond_json(
                    stream,
                    &json!({
                        "issuer":origin,
                        "authorization_endpoint":format!("{origin}/authorize"),
                        "token_endpoint":format!("{origin}/token"),
                        "registration_endpoint":format!("{origin}/register"),
                        "code_challenge_methods_supported":["S256"],
                        "token_endpoint_auth_methods_supported":["none","client_secret_post"],
                        "scopes_supported":["read","offline_access"]
                    }),
                ),
                "/register" => {
                    recorded_registrations.fetch_add(1, Ordering::Relaxed);
                    assert_eq!(request.json()["token_endpoint_auth_method"], "none");
                    respond_json(stream, &json!({"client_id":"test-client"}));
                }
                "/authorize" => {
                    let query = parameters(&request.target);
                    assert_eq!(query["client_id"], "test-client");
                    assert_eq!(query["resource"], oauth_resource);
                    assert_eq!(query["code_challenge_method"], "S256");
                    let count = recorded_authorizations.fetch_add(1, Ordering::Relaxed) + 1;
                    if deny_scope.load(Ordering::Relaxed) {
                        assert_eq!(query["scope"], "read offline_access queue admin");
                        let mut callback = Url::parse(&query["redirect_uri"]).unwrap();
                        callback
                            .query_pairs_mut()
                            .append_pair("state", &query["state"])
                            .append_pair("error", "access_denied");
                        respond(stream, "302 Found", &[("Location", callback.as_str())], "");
                        return;
                    }
                    if preregistered && count > 1 {
                        assert_eq!(query["scope"], "read offline_access queue");
                    } else {
                        assert_eq!(query["scope"], "read offline_access");
                    }
                    let code = format!("code-{count}");
                    proofs
                        .lock()
                        .unwrap()
                        .insert(code.clone(), query["code_challenge"].clone());
                    let mut callback = Url::parse(&query["redirect_uri"]).unwrap();
                    callback
                        .query_pairs_mut()
                        .append_pair("state", &query["state"])
                        .append_pair("code", &code);
                    respond(stream, "302 Found", &[("Location", callback.as_str())], "");
                }
                "/token" => {
                    let form =
                        parameters(&format!("?{}", String::from_utf8(request.body).unwrap()));
                    assert_eq!(form["client_id"], "test-client");
                    assert_eq!(form["resource"], oauth_resource);
                    assert_eq!(
                        form.get("client_secret").map(String::as_str),
                        preregistered.then_some("local-secret")
                    );
                    if form["grant_type"] == "refresh_token" {
                        let refresh = recorded_refreshes.fetch_add(1, Ordering::Relaxed);
                        assert_eq!(form["refresh_token"], "refresh-1");
                        if refresh == 0 {
                            respond_json(
                                stream,
                                &json!({"access_token":"token-refreshed","token_type":"Bearer","expires_in":0}),
                            );
                        } else {
                            respond(
                                stream,
                                "400 Bad Request",
                                &[("Content-Type", "application/json")],
                                if preregistered {
                                    r#"{"error":"invalid_grant"}"#
                                } else {
                                    r#"{"error":"invalid_client"}"#
                                },
                            );
                        }
                    } else {
                        let expected = proofs.lock().unwrap().remove(&form["code"]).unwrap();
                        assert_eq!(
                            URL_SAFE_NO_PAD
                                .encode(Sha256::digest(form["code_verifier"].as_bytes())),
                            expected
                        );
                        respond_json(
                            stream,
                            &json!({
                                "access_token": format!("token-{}", form["code"]),
                                "token_type":"Bearer", "refresh_token":"refresh-1",
                                "expires_in": if preregistered && form["code"] == "code-3" { 3600 } else { 0 }
                            }),
                        );
                    }
                }
                path => panic!("unexpected OAuth request {path}"),
            }
        });
        let temp = tempfile::tempdir().unwrap();
        let auth_dir = temp.path().join("private-auth");
        let mut bootstrap = command(temp.path());
        bootstrap
            .env("MUNRAY_MCP_AUTH_DIR", &auth_dir)
            .env("MUNRAY_TEST_CLIENT_SECRET", "local-secret")
            .args([
                "svc",
                "bootstrap",
                "oauth_demo",
                "--mcp-url",
                &format!("{}/mcp", server.url),
                "--oauth",
                "--no-browser",
                "--timeout",
                "20",
            ]);
        if preregistered {
            bootstrap.args([
                "--oauth-client-id",
                "test-client",
                "--oauth-client-secret-env",
                "MUNRAY_TEST_CLIENT_SECRET",
            ]);
        } else {
            bootstrap.args(["--transport", "sse"]);
        }
        let bootstrap = BrowserCommand::start(bootstrap);
        bootstrap.authorize();
        if preregistered {
            bootstrap.authorize();
        }
        bootstrap.finish();
        assert_eq!(
            rejected_issuer_requests.load(Ordering::Relaxed),
            0,
            "a rejected resource document was used to discover its issuer"
        );

        if !preregistered {
            let session_file = fs::read_dir(&auth_dir)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .find(|path| path.extension().is_some_and(|ext| ext == "json"))
                .unwrap();
            let mut old_session: Value =
                serde_json::from_slice(&fs::read(&session_file).unwrap()).unwrap();
            old_session.as_object_mut().unwrap().remove("resource");
            fs::write(session_file, serde_json::to_vec(&old_session).unwrap()).unwrap();
        }

        let script = temp.path().join("read.lua");
        fs::write(&script, r#"local result, err = oauth_demo.read(); assert(result, err and err.message); return result.content[1].text"#).unwrap();
        let run = || {
            let mut command = command(temp.path());
            command
                .env("MUNRAY_MCP_AUTH_DIR", &auth_dir)
                .env("MUNRAY_TEST_CLIENT_SECRET", "local-secret")
                .arg("run")
                .arg(&script);
            BrowserCommand::start(command)
        };
        assert_eq!(run().finish().trim(), r#""refreshed""#);
        let reauth = run();
        reauth.authorize();
        assert_eq!(
            reauth.finish().trim(),
            if preregistered {
                r#""code-3""#
            } else {
                r#""code-2""#
            }
        );
        assert_eq!(
            authorizations.load(Ordering::Relaxed),
            if preregistered { 3 } else { 2 }
        );
        assert_eq!(refreshes.load(Ordering::Relaxed), 2);
        assert_eq!(
            registrations.load(Ordering::Relaxed),
            if preregistered { 0 } else { 2 }
        );
        if preregistered {
            deny_extra_scope.store(true, Ordering::Relaxed);
            let mut refresh = command(temp.path());
            refresh
                .env("MUNRAY_MCP_AUTH_DIR", &auth_dir)
                .env("MUNRAY_TEST_CLIENT_SECRET", "local-secret")
                .args(["svc", "refresh", "oauth_demo", "--timeout", "10"]);
            let refresh = BrowserCommand::start(refresh);
            refresh.authorize();
            refresh.expect_failure("OAuth provider denied authorization");
            assert_eq!(run().finish().trim(), r#""code-3""#);
        }
        let catalog = fs::read_to_string(temp.path().join("oauth_demo/mcp-catalog.json")).unwrap();
        assert!(!catalog.contains("local-secret"));
        assert!(!catalog.contains("refresh-1"));
    }
}
