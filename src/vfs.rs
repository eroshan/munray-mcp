use std::{
    fs,
    io::{Read, Seek, SeekFrom},
    path::{Component, Path, PathBuf},
    sync::Arc,
};

use mlua::{Lua, LuaSerdeExt, Table, Value};
use parking_lot::Mutex;
use serde_json::json;
use tempfile::TempDir;
use walkdir::WalkDir;
use zip::ZipArchive;

use crate::blob::{BlobRef, BlobStore};
use crate::runtime::lua_error;

const MAX_VFS_BYTES: u64 = 512 * 1024 * 1024;

pub(crate) fn register(
    lua: &Lua,
    raw: &Table,
    root: Arc<TempDir>,
    exposures: Arc<Mutex<Vec<TempDir>>>,
    blobs: BlobStore,
) -> mlua::Result<()> {
    let vfs: Table = raw.get("vfs")?;
    let blob_root = Arc::clone(&root);
    vfs.set(
        "write_blob",
        lua.create_function(
            move |lua, (path, reference, opts): (String, mlua::AnyUserData, Option<Table>)| {
                let reference = match reference.borrow::<BlobRef>() {
                    Ok(reference) => reference.clone(),
                    Err(_) => {
                        return lua_error(
                            lua,
                            "VALIDATION_FAILED",
                            "blob argument is required".into(),
                            false,
                        );
                    }
                };
                let Some(bytes) = blobs.get(&reference) else {
                    return lua_error(lua, "VFS_ERROR", "blob not found".into(), false);
                };
                let (resolved, path) = match resolve(blob_root.path(), &path) {
                    Ok(path) => path,
                    Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
                };
                let overwrite = opts
                    .and_then(|opts| opts.get::<bool>("overwrite").ok())
                    .unwrap_or(true);
                if resolved.exists() && !overwrite {
                    return lua_error(
                        lua,
                        "VFS_ERROR",
                        format!("file already exists: {path}"),
                        false,
                    );
                }
                if let Err(error) =
                    ensure_write_quota(blob_root.path(), &resolved, bytes.len() as u64)
                {
                    return lua_error(lua, "VFS_QUOTA_EXCEEDED", error, false);
                }
                if let Some(parent) = resolved.parent()
                    && let Err(error) = fs::create_dir_all(parent)
                {
                    return lua_error(lua, "VFS_ERROR", error.to_string(), false);
                }
                if let Err(error) = fs::write(&resolved, bytes.as_ref()) {
                    return lua_error(lua, "VFS_ERROR", error.to_string(), false);
                }
                Ok((
                    lua.to_value(&json!({"path":path,"size":bytes.len(),"is_dir":false}))?,
                    Value::Nil,
                ))
            },
        )?,
    )?;

    let text_root = Arc::clone(&root);
    vfs.set(
        "to_text",
        lua.create_function(move |lua, (path, opts): (String, Option<Table>)| {
            match zip_to_text(lua, text_root.path(), &path, opts) {
                Ok(value) => Ok((lua.to_value(&value)?, Value::Nil)),
                Err(error) => lua_error(lua, "VFS_ERROR", error, false),
            }
        })?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set(
        "mkdirp",
        lua.create_function(move |lua, path: String| {
            let (path, _) = match resolve(vfs_root.path(), &path) {
                Ok(path) => path,
                Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
            };
            match fs::create_dir_all(path) {
                Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
                Err(error) => lua_error(lua, "VFS_ERROR", error.to_string(), false),
            }
        })?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set(
        "remove",
        lua.create_function(move |lua, path: String| {
            let (resolved, _) = match resolve(vfs_root.path(), &path) {
                Ok(path) => path,
                Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
            };
            let result = match fs::metadata(&resolved) {
                Ok(metadata) if metadata.is_dir() => fs::remove_dir_all(&resolved),
                Ok(_) => fs::remove_file(&resolved),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    return Ok((Value::Boolean(false), Value::Nil));
                }
                Err(error) => return lua_error(lua, "VFS_ERROR", error.to_string(), false),
            };
            match result {
                Ok(()) => Ok((Value::Boolean(true), Value::Nil)),
                Err(error) => lua_error(lua, "VFS_ERROR", error.to_string(), false),
            }
        })?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set(
        "write_text",
        lua.create_function(
            move |lua, (path, text, opts): (String, String, Option<Table>)| {
                let (resolved, path) = match resolve(vfs_root.path(), &path) {
                    Ok(path) => path,
                    Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
                };
                let overwrite = opts
                    .and_then(|opts| opts.get::<bool>("overwrite").ok())
                    .unwrap_or(true);
                if resolved.exists() && !overwrite {
                    return lua_error(
                        lua,
                        "VFS_ERROR",
                        format!("file already exists: {path}"),
                        false,
                    );
                }
                if let Err(error) =
                    ensure_write_quota(vfs_root.path(), &resolved, text.len() as u64)
                {
                    return lua_error(lua, "VFS_QUOTA_EXCEEDED", error, false);
                }
                if let Some(parent) = resolved.parent()
                    && let Err(error) = fs::create_dir_all(parent)
                {
                    return lua_error(lua, "VFS_ERROR", error.to_string(), false);
                }
                if let Err(error) = fs::write(&resolved, text.as_bytes()) {
                    return lua_error(lua, "VFS_ERROR", error.to_string(), false);
                }
                Ok((
                    lua.to_value(&json!({"path":path,"size":text.len(),"is_dir":false}))?,
                    Value::Nil,
                ))
            },
        )?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set(
        "read_text",
        lua.create_function(move |lua, (path, opts): (String, Option<Table>)| {
            let (resolved, _) = match resolve(vfs_root.path(), &path) {
                Ok(path) => path,
                Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
            };
            let max_bytes = opts
                .as_ref()
                .and_then(|opts| opts.get::<usize>("max_bytes").ok())
                .unwrap_or(1024 * 1024)
                .min(1024 * 1024);
            let offset = opts
                .and_then(|opts| opts.get::<u64>("offset").ok())
                .unwrap_or(0);
            let mut file = match fs::File::open(resolved) {
                Ok(file) => file,
                Err(error) => return lua_error(lua, "VFS_ERROR", error.to_string(), false),
            };
            if let Err(error) = file.seek(SeekFrom::Start(offset)) {
                return lua_error(lua, "VFS_ERROR", error.to_string(), false);
            }
            let mut bytes = Vec::new();
            if let Err(error) = file.take(max_bytes as u64).read_to_end(&mut bytes) {
                return lua_error(lua, "VFS_ERROR", error.to_string(), false);
            }
            match String::from_utf8(bytes) {
                Ok(text) => Ok((Value::String(lua.create_string(&text)?), Value::Nil)),
                Err(error) => lua_error(lua, "VFS_ERROR", error.to_string(), false),
            }
        })?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set(
        "stat",
        lua.create_function(move |lua, path: String| {
            let (resolved, path) = match resolve(vfs_root.path(), &path) {
                Ok(path) => path,
                Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
            };
            match fs::metadata(resolved) {
                Ok(metadata) => Ok((
                    lua.to_value(
                        &json!({"path":path,"size":metadata.len(),"is_dir":metadata.is_dir()}),
                    )?,
                    Value::Nil,
                )),
                Err(error) => lua_error(lua, "VFS_ERROR", error.to_string(), false),
            }
        })?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set(
        "list",
        lua.create_function(move |lua, (path, opts): (String, Option<Table>)| {
            let (resolved, _) = match resolve(vfs_root.path(), &path) {
                Ok(path) => path,
                Err(error) => return lua_error(lua, "VFS_ERROR", error, false),
            };
            let recursive = opts
                .as_ref()
                .and_then(|opts| opts.get::<bool>("recursive").ok())
                .unwrap_or(false);
            let max_entries = opts
                .and_then(|opts| opts.get::<usize>("max_entries").ok())
                .unwrap_or(10_000);
            let depth = if recursive { usize::MAX } else { 1 };
            let entries = WalkDir::new(&resolved)
                .min_depth(1)
                .max_depth(depth)
                .into_iter()
                .filter_map(Result::ok)
                .take(max_entries)
                .filter_map(|entry| {
                    let metadata = entry.metadata().ok()?;
                    let relative = entry
                        .path()
                        .strip_prefix(vfs_root.path())
                        .ok()?
                        .to_string_lossy()
                        .to_string();
                    Some(json!({"path":relative,"size":metadata.len(),"is_dir":metadata.is_dir()}))
                })
                .collect::<Vec<_>>();
            Ok((lua.to_value(&entries)?, Value::Nil))
        })?,
    )?;

    let vfs_root = Arc::clone(&root);
    vfs.set("expose", lua.create_function(move |lua, paths: Table| {
        let bundle = match tempfile::Builder::new().prefix(concat!(env!("CARGO_PKG_NAME"), "-expose-")).tempdir() { Ok(bundle) => bundle, Err(error) => return lua_error(lua, "VFS_ERROR", error.to_string(), false) };
        let mut files = Vec::new();
        for (index, path) in paths.sequence_values::<String>().enumerate() {
            let path = path?;
            let (source, path) = match resolve(vfs_root.path(), &path) { Ok(path) => path, Err(error) => return lua_error(lua, "VFS_ERROR", error, false) };
            if !source.is_file() { return lua_error(lua, "VFS_ERROR", format!("not a file: {path}"), false); }
            let name = source.file_name().and_then(|name| name.to_str()).unwrap_or("file");
            let target = bundle.path().join(format!("{}-{}", index + 1, name));
            if let Err(error) = fs::copy(&source, &target) { return lua_error(lua, "VFS_ERROR", error.to_string(), false); }
            files.push(json!({"original_vfs_path":path,"host_path":target,"size":fs::metadata(&source).map(|meta| meta.len()).unwrap_or(0)}));
        }
        exposures.lock().push(bundle);
        Ok((lua.to_value(&json!({"files":files}))?, Value::Nil))
    })?)?;
    Ok(())
}

/// Treats leading slashes as VFS-root markers rather than host absolute paths.
fn normalize_path(path: &str) -> &str {
    path.trim_start_matches('/')
}

fn resolve<'a>(root: &Path, path: &'a str) -> Result<(PathBuf, &'a str), String> {
    let relative = normalize_path(path);
    if relative.is_empty() {
        return Err("VFS path must not be empty".into());
    }
    let path = Path::new(relative);
    if path.is_absolute()
        || path.components().any(|part| {
            matches!(
                part,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(format!("invalid VFS path: {relative}"));
    }
    if !relative
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'/' | b'-'))
    {
        return Err(format!("invalid characters in VFS path: {relative}"));
    }
    Ok((root.join(path), relative))
}

const ZIP_MAX_ENTRIES: usize = 1_000;
const ZIP_MAX_EXPANDED_BYTES: u64 = 100 * 1024 * 1024;
const ZIP_MAX_COMPRESSION_RATIO: u64 = 100;
const ZIP_MAX_PREVIEW_BYTES: usize = 1024 * 1024;

fn vfs_bytes(root: &Path) -> u64 {
    WalkDir::new(root)
        .into_iter()
        .filter_map(Result::ok)
        .filter_map(|entry| entry.metadata().ok())
        .filter(|metadata| metadata.is_file())
        .map(|metadata| metadata.len())
        .sum()
}

fn ensure_write_quota(root: &Path, destination: &Path, size: u64) -> Result<(), String> {
    let replaced = fs::metadata(destination)
        .map(|metadata| metadata.len())
        .unwrap_or(0);
    let projected = vfs_bytes(root)
        .saturating_sub(replaced)
        .saturating_add(size);
    if projected > MAX_VFS_BYTES {
        return Err(format!(
            "runtime VFS quota is {MAX_VFS_BYTES} bytes (requested projected size {projected})"
        ));
    }
    Ok(())
}

fn zip_to_text(
    _lua: &Lua,
    root: &Path,
    vfs_path: &str,
    opts: Option<Table>,
) -> Result<serde_json::Value, String> {
    let (archive_path, vfs_path) = resolve(root, vfs_path)?;
    if !vfs_path.to_ascii_lowercase().ends_with(".zip") {
        return Err("unsupported to_text format".into());
    }
    let max_files = opts
        .as_ref()
        .and_then(|opts| opts.get::<usize>("max_files").ok())
        .unwrap_or(50)
        .min(ZIP_MAX_ENTRIES);
    let preview_per_file = opts
        .as_ref()
        .and_then(|opts| opts.get::<usize>("preview_bytes_per_file").ok())
        .unwrap_or(4096)
        .min(ZIP_MAX_PREVIEW_BYTES);
    let total_preview_limit = opts
        .as_ref()
        .and_then(|opts| opts.get::<usize>("total_preview_bytes").ok())
        .unwrap_or(200 * 1024)
        .min(ZIP_MAX_PREVIEW_BYTES);
    let default_dir = format!(
        "extracted/{}",
        Path::new(vfs_path)
            .file_stem()
            .and_then(|name| name.to_str())
            .unwrap_or("archive")
    );
    let extract_dir = opts
        .and_then(|opts| opts.get::<String>("extract_dir").ok())
        .unwrap_or(default_dir);
    let (_, extract_dir) = resolve(root, &extract_dir)?;

    let file =
        fs::File::open(archive_path).map_err(|error| format!("failed to open zip: {error}"))?;
    let mut archive =
        ZipArchive::new(file).map_err(|error| format!("invalid zip archive: {error}"))?;
    if archive.len() > ZIP_MAX_ENTRIES {
        return Err(format!(
            "ZIP_QUOTA_EXCEEDED: archive has {} entries; limit is {ZIP_MAX_ENTRIES}",
            archive.len()
        ));
    }
    let mut descriptors = Vec::new();
    let mut expanded = 0_u64;
    for index in 0..archive.len() {
        let entry = archive
            .by_index(index)
            .map_err(|error| format!("failed to inspect zip entry: {error}"))?;
        if entry.is_dir() {
            continue;
        }
        let name = entry.name().to_owned();
        let entry_path = Path::new(&name);
        if entry_path.is_absolute()
            || entry_path.components().any(|part| {
                matches!(
                    part,
                    Component::ParentDir | Component::RootDir | Component::Prefix(_)
                )
            })
        {
            return Err(format!("ZIP_INVALID_ENTRY: unsafe archive entry {name:?}"));
        }
        let compressed = entry.compressed_size();
        let size = entry.size();
        if size > ZIP_MAX_EXPANDED_BYTES
            || (compressed == 0 && size > 0)
            || (compressed > 0 && size / compressed > ZIP_MAX_COMPRESSION_RATIO)
        {
            return Err(format!(
                "ZIP_QUOTA_EXCEEDED: entry {name:?} exceeds compression-ratio limit"
            ));
        }
        expanded = expanded
            .checked_add(size)
            .ok_or_else(|| "ZIP_QUOTA_EXCEEDED: expanded size overflow".to_owned())?;
        if expanded > ZIP_MAX_EXPANDED_BYTES {
            return Err(format!(
                "ZIP_QUOTA_EXCEEDED: expanded bytes exceed {ZIP_MAX_EXPANDED_BYTES}"
            ));
        }
        descriptors.push((index, name));
    }
    if vfs_bytes(root).saturating_add(expanded) > MAX_VFS_BYTES {
        return Err(format!(
            "VFS_QUOTA_EXCEEDED: ZIP extraction would exceed runtime VFS quota of {MAX_VFS_BYTES} bytes"
        ));
    }
    let mut files = Vec::new();
    let mut preview_used = 0;
    for (index, name) in descriptors.iter().take(max_files) {
        if crate::deadline::effective(std::time::Duration::from_secs(1)).is_none() {
            return Err("TIMEOUT: execution deadline exceeded during ZIP extraction".into());
        }
        let mut entry = archive
            .by_index(*index)
            .map_err(|error| format!("failed to read zip entry: {error}"))?;
        let mut bytes = Vec::with_capacity(usize::try_from(entry.size()).unwrap_or(0));
        entry
            .read_to_end(&mut bytes)
            .map_err(|error| format!("failed to extract zip entry {name:?}: {error}"))?;
        let entry_path = format!("{extract_dir}/{name}");
        let (destination, _) = resolve(root, &entry_path)?;
        if let Some(parent) = destination.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        fs::write(&destination, &bytes).map_err(|error| error.to_string())?;
        let mut item = json!({"path":entry_path,"bytes":bytes.len()});
        if is_text_extension(name) && preview_used < total_preview_limit {
            let amount = preview_per_file
                .min(total_preview_limit - preview_used)
                .min(bytes.len());
            if amount > 0
                && let Ok(preview) = std::str::from_utf8(&bytes[..amount])
            {
                item["preview"] = json!(preview);
                preview_used += preview.len();
            }
        }
        files.push(item);
    }
    let suffix = if descriptors.len() > max_files {
        format!(" (showing first {max_files})")
    } else {
        String::new()
    };
    Ok(
        json!({"kind":"zip", "extracted_dir":format!("{extract_dir}/"), "summary":format!("Zip archive with {} files{suffix}", descriptors.len()), "files":files, "truncated":descriptors.len() > max_files}),
    )
}

fn is_text_extension(name: &str) -> bool {
    matches!(
        Path::new(name)
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str(),
        "txt"
            | "log"
            | "md"
            | "json"
            | "xml"
            | "yml"
            | "yaml"
            | "csv"
            | "env"
            | "properties"
            | "ini"
            | "conf"
            | "cfg"
            | "toml"
            | "tf"
            | "hcl"
            | "sh"
            | "py"
            | "go"
            | "lua"
            | "js"
            | "ts"
            | "html"
            | "css"
            | "sql"
    )
}
