use std::{
    io::{BufRead, BufReader, Read, Write},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use interprocess::local_socket::{
    GenericNamespaced, ListenerNonblockingMode, ListenerOptions, ToNsName, prelude::*,
};
use serde::{Deserialize, Serialize};

use crate::mcp::McpServer;

pub const MAX_INGEST_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
pub struct IngestHeader {
    pub op: String,
    pub session_id: String,
    pub bytes: usize,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct IngestError {
    pub code: String,
    pub message: String,
    pub recoverable: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct IngestResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bytes: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<IngestError>,
}

impl IngestResponse {
    fn failure(code: &str, message: impl Into<String>) -> Self {
        Self {
            ok: false,
            token: None,
            bytes: None,
            error: Some(IngestError {
                code: code.into(),
                message: message.into(),
                recoverable: false,
            }),
        }
    }
}

pub struct IngestListenerGuard {
    shutdown: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for IngestListenerGuard {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take()
            && thread.thread().id() != thread::current().id()
        {
            let _ = thread.join();
        }
    }
}

fn endpoint(server_id: &str) -> String {
    format!("{}-ingest-{server_id}", env!("CARGO_PKG_NAME"))
}

pub fn start_listener(server: McpServer, server_id: &str) -> std::io::Result<IngestListenerGuard> {
    let raw_name = endpoint(server_id);
    let name = raw_name.to_ns_name::<GenericNamespaced>()?;
    let listener = ListenerOptions::new()
        .name(name)
        .nonblocking(ListenerNonblockingMode::Accept)
        .create_sync()?;
    let shutdown = Arc::new(AtomicBool::new(false));
    let thread_shutdown = Arc::clone(&shutdown);
    let thread = thread::spawn(move || {
        while !thread_shutdown.load(Ordering::Acquire) {
            match listener.accept() {
                Ok(stream) => {
                    let server = server.clone();
                    thread::spawn(move || handle_connection(server, stream));
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(_) => break,
            }
        }
    });

    Ok(IngestListenerGuard {
        shutdown,
        thread: Some(thread),
    })
}

fn handle_connection(server: McpServer, mut stream: LocalSocketStream) {
    let response = read_request(&mut stream).and_then(|(header, payload)| {
        if header.op != "ingest_text_v1" {
            return Err(IngestResponse::failure(
                "IPC_UNAVAILABLE",
                "unsupported ingest operation",
            ));
        }
        if header.session_id.trim().is_empty() {
            return Err(IngestResponse::failure(
                "SESSION_NOT_FOUND",
                "unknown or expired session",
            ));
        }
        let text = String::from_utf8(payload)
            .map_err(|_| IngestResponse::failure("INVALID_UTF8", "stdin is not valid UTF-8"))?;
        server
            .ingest_existing(&header.session_id, &text)
            .map(|token| IngestResponse {
                ok: true,
                token: Some(token),
                bytes: Some(header.bytes),
                error: None,
            })
            .map_err(|error| IngestResponse::failure("SESSION_NOT_FOUND", error))
    });
    let response = response.unwrap_or_else(|error| error);
    if let Ok(mut encoded) = serde_json::to_vec(&response) {
        encoded.push(b'\n');
        let _ = stream.write_all(&encoded);
    }
}

fn read_request(stream: &mut impl Read) -> Result<(IngestHeader, Vec<u8>), IngestResponse> {
    let mut reader = BufReader::new(stream);
    let mut header_line = String::new();
    reader
        .read_line(&mut header_line)
        .map_err(|error| IngestResponse::failure("IPC_UNAVAILABLE", error.to_string()))?;
    let header: IngestHeader = serde_json::from_str(&header_line)
        .map_err(|error| IngestResponse::failure("IPC_UNAVAILABLE", error.to_string()))?;
    if header.bytes > MAX_INGEST_BYTES {
        return Err(IngestResponse::failure(
            "INGEST_TOO_LARGE",
            format!("payload exceeds {MAX_INGEST_BYTES} bytes"),
        ));
    }
    let mut payload = vec![0; header.bytes];
    reader
        .read_exact(&mut payload)
        .map_err(|error| IngestResponse::failure("IPC_UNAVAILABLE", error.to_string()))?;
    Ok((header, payload))
}

pub fn send_text(
    server_id: &str,
    session_id: &str,
    payload: &[u8],
) -> Result<IngestResponse, String> {
    let raw_name = endpoint(server_id);
    let name = raw_name
        .to_ns_name::<GenericNamespaced>()
        .map_err(|error| error.to_string())?;
    let mut stream = LocalSocketStream::connect(name).map_err(|error| error.to_string())?;
    let mut header = serde_json::to_vec(&IngestHeader {
        op: "ingest_text_v1".into(),
        session_id: session_id.into(),
        bytes: payload.len(),
    })
    .map_err(|error| error.to_string())?;
    header.push(b'\n');
    stream
        .write_all(&header)
        .map_err(|error| error.to_string())?;
    stream
        .write_all(payload)
        .map_err(|error| error.to_string())?;
    let mut response = String::new();
    BufReader::new(&mut stream)
        .read_line(&mut response)
        .map_err(|error| error.to_string())?;
    serde_json::from_str(&response).map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dropping_listener_guard_releases_endpoint() {
        let server_id = format!("drop-{}", uuid::Uuid::new_v4());
        let guard = start_listener(McpServer::new(None).unwrap(), &server_id).unwrap();
        drop(guard);

        let raw_name = endpoint(&server_id);
        let name = raw_name.to_ns_name::<GenericNamespaced>().unwrap();
        ListenerOptions::new().name(name).create_sync().unwrap();
    }
}
