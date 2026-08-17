use std::{
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};
use mlua::Lua;
use walkdir::WalkDir;

#[derive(Clone, Debug)]
pub struct ServicePack {
    pub name: String,
    pub directory: PathBuf,
    pub source_files: Vec<PathBuf>,
    pub nested_init_files: Vec<PathBuf>,
}

#[derive(Clone, Debug, Default)]
pub struct LoadReport {
    pub packs: Vec<ServicePack>,
}

/// Load every service pack and return the exact directories and source modules
/// that were accepted. A pack is an immediate child of `service_dir` with a
/// `src` directory; `src/init.lua` is its entrypoint, while any nested
/// `init.lua` remains an ordinary module.
pub fn load(lua: &Lua, service_dir: &Path) -> Result<LoadReport> {
    if !service_dir.is_dir() {
        return Ok(LoadReport::default());
    }

    let mut packs = Vec::new();
    for entry in fs::read_dir(service_dir)
        .with_context(|| format!("cannot read services directory {}", service_dir.display()))?
    {
        let entry =
            entry.with_context(|| format!("cannot read entry in {}", service_dir.display()))?;
        let name = entry.file_name().to_string_lossy().to_string();
        let path = entry.path();
        if name.starts_with('.') || !entry.metadata()?.is_dir() || !path.join("src").is_dir() {
            continue;
        }
        packs.push((name, path));
    }
    packs.sort_by(|(left, _), (right, _)| left.cmp(right));

    let examples = lua.create_table()?;
    let mut report = LoadReport::default();
    for (name, directory) in packs {
        let src = directory.join("src");
        let entrypoint = src.join("init.lua");
        if !entrypoint.is_file() {
            anyhow::bail!(
                "service pack {} is missing required entrypoint {}",
                directory.display(),
                entrypoint.display()
            );
        }
        let mut source_files = walk_lua_files(&src, "service source")?;
        source_files.sort();
        let nested_init_files = source_files
            .iter()
            .filter(|path| {
                path.file_name().is_some_and(|file| file == "init.lua") && *path != &entrypoint
            })
            .cloned()
            .collect();

        // Only the pack-root init.lua is an entrypoint. Nested init.lua files
        // are loaded with the rest of the modules in deterministic path order.
        source_files.retain(|path| path != &entrypoint);
        source_files.insert(0, entrypoint.clone());
        for path in &source_files {
            let source = fs::read_to_string(path)
                .with_context(|| format!("cannot read service module {}", path.display()))?;
            lua.load(&source)
                .set_name(path.to_string_lossy())
                .exec()
                .with_context(|| format!("failed to load service module {}", path.display()))?;
        }

        let examples_dir = directory.join("examples");
        if examples_dir.is_dir() {
            for path in walk_lua_files(&examples_dir, "service examples")? {
                let relative = path.strip_prefix(&examples_dir)?;
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
                let key = if parts.len() == 1 && parts[0] == name {
                    name.clone()
                } else {
                    format!("{}.{}", name, parts.join("."))
                };
                examples.set(
                    key,
                    fs::read_to_string(&path).with_context(|| {
                        format!("cannot read service example {}", path.display())
                    })?,
                )?;
            }
        }
        report.packs.push(ServicePack {
            name,
            directory,
            source_files,
            nested_init_files,
        });
    }
    lua.globals().set("_examples", examples)?;
    Ok(report)
}

fn walk_lua_files(root: &Path, label: &str) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for entry in WalkDir::new(root).follow_links(true) {
        let entry =
            entry.with_context(|| format!("cannot walk {label} under {}", root.display()))?;
        if entry.file_type().is_file()
            && entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "lua")
        {
            files.push(entry.into_path());
        }
    }
    Ok(files)
}

pub fn validate(service_dir: &Path) -> Result<usize> {
    crate::validate::run(service_dir)
}
