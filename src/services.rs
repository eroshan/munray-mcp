use std::{fs, path::Path};

use anyhow::{Context, Result};
use mlua::Lua;
use walkdir::WalkDir;

pub fn load(lua: &Lua, service_dir: &Path) -> Result<()> {
    if !service_dir.is_dir() {
        return Ok(());
    }
    let mut services = fs::read_dir(service_dir)?
        .filter_map(Result::ok)
        .filter(|entry| {
            !entry.file_name().to_string_lossy().starts_with('.')
                && entry.path().is_dir()
                && entry.path().join("src").is_dir()
        })
        .collect::<Vec<_>>();
    services.sort_by_key(|entry| entry.file_name());

    let examples = lua.create_table()?;
    for service in services {
        let service_name = service.file_name().to_string_lossy().to_string();
        let src = service.path().join("src");
        if !src.is_dir() {
            continue;
        }
        let mut files = WalkDir::new(&src)
            .follow_links(true)
            .into_iter()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry.file_type().is_file()
                    && entry.path().extension().is_some_and(|ext| ext == "lua")
            })
            .map(|entry| entry.into_path())
            .collect::<Vec<_>>();
        files.sort();
        // The service entry point always precedes its resources.  The validator
        // uses the same candidate rules as the runtime loader.
        files.sort_by_key(|path| path.file_name().is_none_or(|name| name != "init.lua"));
        for path in files {
            let source = fs::read_to_string(&path)?;
            lua.load(&source)
                .set_name(path.to_string_lossy())
                .exec()
                .with_context(|| format!("failed to load service module {}", path.display()))?;
        }
        let examples_dir = service.path().join("examples");
        if examples_dir.is_dir() {
            for entry in WalkDir::new(&examples_dir)
                .follow_links(true)
                .into_iter()
                .filter_map(Result::ok)
                .filter(|entry| {
                    entry.file_type().is_file()
                        && entry.path().extension().is_some_and(|ext| ext == "lua")
                })
            {
                let relative = entry.path().strip_prefix(&examples_dir)?;
                let mut parts = relative
                    .components()
                    .map(|part| part.as_os_str().to_string_lossy().to_string())
                    .collect::<Vec<_>>();
                if let Some(last) = parts.last_mut() {
                    *last = last.trim_end_matches(".lua").to_owned();
                }
                for part in &mut parts {
                    *part = part.replace('_', ".");
                }
                let key = if parts.len() == 1 && parts[0] == service_name {
                    service_name.clone()
                } else {
                    format!("{}.{}", service_name, parts.join("."))
                };
                examples.set(key, fs::read_to_string(entry.path())?)?;
            }
        }
    }
    lua.globals().set("_examples", examples)?;
    Ok(())
}

pub fn validate(service_dir: &Path) -> Result<usize> {
    crate::validate::run(service_dir)
}
