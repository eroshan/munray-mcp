use std::{collections::HashMap, fs, sync::Arc};

use walkdir::WalkDir;

use mlua::{Lua, Table, Value};
use parking_lot::Mutex;
use tempfile::TempDir;

use crate::runtime::lua_error;

const MAX_BYTES: usize = 64 * 1024 * 1024;
const MAX_VFS_BYTES: u64 = 512 * 1024 * 1024;

fn vfs_bytes(root: &std::path::Path) -> u64 {
    WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

#[derive(Clone)]
pub(crate) struct IngestStore {
    root: Arc<TempDir>,
    entries: Arc<Mutex<HashMap<String, String>>>,
}

impl IngestStore {
    pub(crate) fn new(root: Arc<TempDir>) -> Self {
        Self {
            root,
            entries: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub(crate) fn store(&self, text: &str) -> Result<String, String> {
        if text.len() > MAX_BYTES {
            return Err(format!("ingest content exceeds {MAX_BYTES} bytes"));
        }
        if vfs_bytes(self.root.path()).saturating_add(text.len() as u64) > MAX_VFS_BYTES {
            return Err(format!(
                "VFS_QUOTA_EXCEEDED: runtime VFS quota is {MAX_VFS_BYTES} bytes"
            ));
        }
        let token = format!("ing_{}", uuid::Uuid::new_v4().simple());
        let relative = format!("__ingest/{token}.txt");
        let path = self.root.path().join(&relative);
        fs::create_dir_all(path.parent().expect("ingest path has parent"))
            .map_err(|error| error.to_string())?;
        fs::write(path, text).map_err(|error| error.to_string())?;
        self.entries.lock().insert(token.clone(), relative);
        Ok(token)
    }
}

pub(crate) fn register(lua: &Lua, raw: &Table, store: IngestStore) -> mlua::Result<()> {
    let ingest: Table = raw.get("ingest")?;
    ingest.set(
        "get",
        lua.create_function(move |lua, token: String| {
            if !valid_token(&token) {
                return lua_error(
                    lua,
                    "INVALID_TOKEN",
                    "ingest token must match ^ing_[0-9a-f]{32}$".into(),
                    true,
                );
            }
            let relative = match store.entries.lock().get(&token).cloned() {
                Some(relative) => relative,
                None => {
                    return lua_error(
                        lua,
                        "TOKEN_NOT_FOUND",
                        format!("ingest token not found: {token}"),
                        true,
                    );
                }
            };
            match fs::read_to_string(store.root.path().join(relative)) {
                Ok(text) if text.len() <= MAX_BYTES => {
                    Ok((Value::String(lua.create_string(&text)?), Value::Nil))
                }
                Ok(_) => lua_error(
                    lua,
                    "INGEST_READ_FAILED",
                    "ingest content is too large".into(),
                    false,
                ),
                Err(error) => lua_error(lua, "INGEST_READ_FAILED", error.to_string(), false),
            }
        })?,
    )?;
    Ok(())
}

fn valid_token(token: &str) -> bool {
    token.len() == 36
        && token.starts_with("ing_")
        && token[4..]
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}
