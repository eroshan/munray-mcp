#[cfg(unix)]
use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    path::PathBuf,
    thread,
};

use serde::{Deserialize, Serialize};

use crate::mcp::LuarisMcpServer;

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

#[cfg(unix)]
pub struct IngestListenerGuard {
    path: PathBuf,
}

#[cfg(unix)]
impl Drop for IngestListenerGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(unix)]
pub fn endpoint(server_id: &str) -> PathBuf {
    std::env::temp_dir().join(format!("luaris-mcp-ingest-{server_id}.sock"))
}

#[cfg(unix)]
pub fn start_listener(
    server: LuarisMcpServer,
    server_id: &str,
) -> std::io::Result<IngestListenerGuard> {
    let path = endpoint(server_id);
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { break };
            let server = server.clone();
            thread::spawn(move || handle_connection(server, stream));
        }
    });
    Ok(IngestListenerGuard { path })
}

#[cfg(unix)]
fn handle_connection(server: LuarisMcpServer, mut stream: UnixStream) {
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

#[cfg(unix)]
fn read_request(stream: &mut UnixStream) -> Result<(IngestHeader, Vec<u8>), IngestResponse> {
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

#[cfg(unix)]
pub fn send_text(
    server_id: &str,
    session_id: &str,
    payload: &[u8],
) -> Result<IngestResponse, String> {
    let mut stream = UnixStream::connect(endpoint(server_id)).map_err(|error| error.to_string())?;
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
    BufReader::new(stream)
        .read_line(&mut response)
        .map_err(|error| error.to_string())?;
    serde_json::from_str(&response).map_err(|error| error.to_string())
}
