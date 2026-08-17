use std::{
    collections::HashSet,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Serialize, Deserialize)]
pub struct ExecutionEntry {
    pub timestamp_ms: u128,
    pub session_id: String,
    pub mode: String,
    pub code: String,
    pub output: String,
    pub result: Value,
    pub error: Option<String>,
    pub duration_ms: u128,
}

#[derive(Debug, Serialize)]
pub struct Stats {
    pub log_path: PathBuf,
    pub executions: usize,
    pub errors: usize,
    pub readonly: usize,
    pub guarded: usize,
    pub sessions: usize,
    pub total_duration_ms: u128,
    pub average_duration_ms: f64,
}

#[derive(Clone)]
pub struct Logger {
    path: PathBuf,
    writer: Arc<Mutex<()>>,
    /// Raw execution data is opt-in because code, output, and values commonly
    /// contain bearer tokens and credentials.
    include_sensitive: bool,
}

impl Logger {
    pub fn new(directory: &Path) -> Result<Self> {
        let existed = directory.exists();
        fs::create_dir_all(directory)?;
        #[cfg(unix)]
        if !existed {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        }
        Ok(Self {
            path: directory.join("executions.jsonl"),
            writer: Arc::new(Mutex::new(())),
            include_sensitive: std::env::var("MUNRAY_MCP_LOG_RAW").ok().as_deref() == Some("1"),
        })
    }

    pub fn log(&self, mut entry: ExecutionEntry) -> Result<()> {
        if entry.timestamp_ms == 0 {
            entry.timestamp_ms = now_ms();
        }
        if !self.include_sensitive {
            entry.code = "[redacted; set MUNRAY_MCP_LOG_RAW=1 to include execution data]".into();
            entry.output = "[redacted]".into();
            entry.result = Value::String("[redacted]".into());
            entry.error = entry.error.map(|_| "[redacted]".into());
        }
        let encoded = serde_json::to_vec(&entry)?;
        let _guard = self.writer.lock();
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(&encoded)?;
        file.write_all(b"\n")?;
        Ok(())
    }
}

pub fn read_stats(directory: &Path) -> Result<Stats> {
    let path = directory.join("executions.jsonl");
    let mut entries = Vec::new();
    if path.exists() {
        for (index, line) in BufReader::new(fs::File::open(&path)?).lines().enumerate() {
            let line = line?;
            if line.trim().is_empty() {
                continue;
            }
            entries.push(
                serde_json::from_str::<ExecutionEntry>(&line).with_context(|| {
                    format!(
                        "invalid execution log entry at {}:{}",
                        path.display(),
                        index + 1
                    )
                })?,
            );
        }
    }
    let errors = entries.iter().filter(|entry| entry.error.is_some()).count();
    let readonly = entries
        .iter()
        .filter(|entry| entry.mode == "readonly")
        .count();
    let guarded = entries
        .iter()
        .filter(|entry| entry.mode == "guarded")
        .count();
    let sessions = entries
        .iter()
        .map(|entry| entry.session_id.as_str())
        .collect::<HashSet<_>>()
        .len();
    let total_duration_ms = entries.iter().map(|entry| entry.duration_ms).sum();
    Ok(Stats {
        log_path: path,
        executions: entries.len(),
        errors,
        readonly,
        guarded,
        sessions,
        total_duration_ms,
        average_duration_ms: if entries.is_empty() {
            0.0
        } else {
            total_duration_ms as f64 / entries.len() as f64
        },
    })
}

pub fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
