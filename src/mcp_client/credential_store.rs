use super::oauth::Session;
use anyhow::{Context, Result, ensure};
use fs2::FileExt;
use std::{
    env, fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

const MAX_AUTH_JSON: usize = 1024 * 1024;

/// Access to one OAuth session. The implementation holds exclusive access
/// for its lifetime, including the refresh or login between load and save.
pub(super) trait CredentialStore: Send + Sync {
    fn load(&self) -> Result<Option<Session>>;
    fn save(&self, session: &Session) -> Result<()>;
}

struct JsonCredentialStore {
    path: PathBuf,
    _lock: fs::File,
}

pub(super) async fn open(key: &str) -> Result<impl CredentialStore> {
    let directory = credential_directory()?;
    let lock = private_file(&directory.join(format!("{key}.lock")), true)?;
    loop {
        match FileExt::try_lock_exclusive(&lock) {
            Ok(()) => break,
            Err(error) if error.raw_os_error() == fs2::lock_contended_error().raw_os_error() => {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Err(error) => return Err(error).context("lock MCP OAuth credentials"),
        }
    }
    Ok(JsonCredentialStore {
        path: directory.join(format!("{key}.json")),
        _lock: lock,
    })
}

fn credential_directory() -> Result<PathBuf> {
    let path = env::var_os("MUNRAY_MCP_AUTH_DIR")
        .filter(|path| !path.is_empty())
        .map(PathBuf::from)
        .or_else(|| {
            env::var_os("MUNRAY_MCP_HOME")
                .filter(|path| !path.is_empty())
                .map(PathBuf::from)
                .or_else(|| {
                    env::var_os("HOME")
                        .filter(|path| !path.is_empty())
                        .map(|path| {
                            PathBuf::from(path)
                                .join(".local/share")
                                .join(env!("CARGO_PKG_NAME"))
                        })
                })
                .map(|home| home.join("mcp-auth"))
        })
        .context("set MUNRAY_MCP_AUTH_DIR, MUNRAY_MCP_HOME or HOME for OAuth credentials")?;
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(&path)?;
    let metadata = fs::symlink_metadata(&path)?;
    ensure!(
        metadata.is_dir(),
        "MCP OAuth credential directory must be a real directory"
    );
    check_owner(&metadata)?;
    Ok(path)
}

fn private_file(path: &Path, lock: bool) -> std::io::Result<fs::File> {
    let mut options = fs::OpenOptions::new();
    options.read(true).write(lock).create(lock);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(std::io::Error::other(
            "MCP OAuth credentials must be a regular file",
        ));
    }
    check_owner(&metadata).map_err(std::io::Error::other)?;
    Ok(file)
}

fn check_owner(metadata: &fs::Metadata) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no memory or argument preconditions.
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0,
            "MCP OAuth credential storage must be accessible only to its owner"
        );
    }
    #[cfg(not(unix))]
    let _ = metadata;
    Ok(())
}

impl CredentialStore for JsonCredentialStore {
    fn load(&self) -> Result<Option<Session>> {
        let file = match private_file(&self.path, false) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).context("open MCP OAuth credentials"),
        };
        let mut data = Vec::new();
        file.take((MAX_AUTH_JSON + 1) as u64)
            .read_to_end(&mut data)?;
        ensure!(
            data.len() <= MAX_AUTH_JSON,
            "MCP OAuth credentials exceed 1 MiB"
        );
        serde_json::from_slice(&data)
            .map(Some)
            .map_err(|_| anyhow::anyhow!("invalid cached MCP OAuth credentials"))
    }

    fn save(&self, session: &Session) -> Result<()> {
        let mut file = tempfile::NamedTempFile::new_in(
            self.path.parent().context("missing credential directory")?,
        )?;
        serde_json::to_writer(&mut file, session)?;
        file.flush()?;
        file.as_file().sync_all()?;
        file.persist(&self.path).map_err(|error| error.error)?;
        Ok(())
    }
}
