use std::{
    io::{Read, Write},
    net::TcpListener,
    thread,
};

use luaris_mcp::runtime::{ExecutionMode, LuaRuntime};

fn one_shot_server(response: &'static str) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0_u8; 4096];
        let _ = stream.read(&mut request).unwrap();
        stream.write_all(response.as_bytes()).unwrap();
    });
    format!("http://{address}/api")
}

fn response_server(responses: Vec<&'static str>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        for response in responses {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let _ = stream.read(&mut request).unwrap();
            stream.write_all(response.as_bytes()).unwrap();
        }
    });
    format!("http://{address}")
}

#[test]
#[ignore = "requires loopback TCP permissions unavailable in the managed sandbox"]
fn http_request_preserves_base_path_and_decodes_json() {
    let base = one_shot_server(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}",
    );
    let runtime = LuaRuntime::new(None).unwrap();
    let code = format!(
        "local value, err = _raw.http.request('GET', '{}', '/items', {{ query = {{ page = 2 }} }})\nif err then error(err.message) end\nreturn value",
        base
    );
    let result = runtime
        .execute(&code, ExecutionMode::ReadOnly, "<test>")
        .unwrap();
    assert_eq!(result.result["ok"], true);
}

#[test]
#[ignore = "requires loopback TCP permissions unavailable in the managed sandbox"]
fn graphql_request_returns_data_by_default() {
    let base = one_shot_server(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 28\r\nConnection: close\r\n\r\n{\"data\":{\"viewer\":{\"id\":7}}}",
    );
    let runtime = LuaRuntime::new(None).unwrap();
    let code = format!(
        "local value, err = _raw.graphql.request('{}', 'query {{ viewer {{ id }} }}', {{ path = '/graphql' }})\nif err then error(err.message) end\nreturn value.viewer.id",
        base
    );
    let result = runtime
        .execute(&code, ExecutionMode::ReadOnly, "<test>")
        .unwrap();
    assert_eq!(result.result, 7);
}

#[test]
#[ignore = "requires loopback TCP permissions unavailable in the managed sandbox"]
fn http_list_supports_page_pagination() {
    let base = response_server(vec![
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 29\r\nConnection: close\r\n\r\n{\"items\":[{\"id\":1},{\"id\":2}]}",
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"items\":[]}",
    ]);
    let runtime = LuaRuntime::new(None).unwrap();
    let code = format!(
        "local iter = _raw.http.list('GET', '{}', '/items', {{ per_page = 2, pagination = {{ kind = 'page', items_path = 'items' }} }})\nlocal values, err = helpers.collect(iter)\nif err then error(err.message) end\nreturn #values",
        base
    );
    let result = runtime
        .execute(&code, ExecutionMode::ReadOnly, "<test>")
        .unwrap();
    assert_eq!(result.result, 2);
}
