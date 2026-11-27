use anyhow::{Context, Result, bail, ensure};
use reqwest::Url;
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, fs::File, io::Read, path::Path, time::Duration};

pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Clone, Copy, Default, Deserialize, Serialize, clap::ValueEnum)]
#[serde(rename_all = "lowercase")]
pub enum Transport {
    #[default]
    Http,
    Sse,
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct OAuth {
    pub client_id: Option<String>,
    pub client_secret_env: Option<String>,
    pub callback_url: Option<String>,
    pub scope: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Connection {
    pub url: String,
    #[serde(default)]
    pub transport: Transport,
    pub token_env: Option<String>,
    pub oauth: Option<OAuth>,
    #[serde(default)]
    pub no_browser: bool,
}

impl Connection {
    pub fn validate(&self) -> Result<Url> {
        let url = endpoint(&self.url)?;
        ensure!(
            self.token_env.is_none() || self.oauth.is_none(),
            "select either bearer token or OAuth"
        );
        if let Some(name) = &self.token_env {
            validate_env_name(name)?;
        }
        if let Some(oauth) = &self.oauth {
            if let Some(id) = &oauth.client_id {
                ensure!(!id.trim().is_empty(), "OAuth client ID is empty");
            }
            if let Some(name) = &oauth.client_secret_env {
                ensure!(
                    oauth.client_id.is_some(),
                    "OAuth client secret requires a client ID"
                );
                validate_env_name(name)?;
            }
            oauth.callback()?;
        }
        Ok(url)
    }
}

impl OAuth {
    pub(super) fn callback(&self) -> Result<Url> {
        let mut url = Url::parse(
            self.callback_url
                .as_deref()
                .unwrap_or("http://127.0.0.1:0/callback"),
        )
        .map_err(|_| anyhow::anyhow!("invalid OAuth callback URL"))?;
        ensure!(
            url.scheme() == "http"
                && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
                && url.username().is_empty()
                && url.password().is_none()
                && url.query().is_none()
                && url.fragment().is_none(),
            "OAuth callback must be an HTTP loopback URL without userinfo, query, or fragment"
        );
        if url.path() == "/" {
            url.set_path("/callback");
        }
        Ok(url)
    }
}

pub(super) fn endpoint(input: &str) -> Result<Url> {
    let url =
        Url::parse(input).map_err(|_| anyhow::anyhow!("invalid MCP or OAuth endpoint URL"))?;
    ensure!(
        url.host().is_some()
            && url.username().is_empty()
            && url.password().is_none()
            && url.fragment().is_none()
            && (url.scheme() == "https"
                || url.scheme() == "http" && matches!(url.host_str(), Some("127.0.0.1" | "[::1]"))),
        "endpoint must be HTTPS or literal loopback HTTP, without userinfo or a fragment"
    );
    Ok(url)
}

fn validate_env_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty() && !name.contains(['=', '\0']),
        "invalid secret environment variable name"
    );
    Ok(())
}

pub(super) fn secret(name: &str) -> Result<String> {
    let value =
        std::env::var(name).with_context(|| format!("read secret environment variable {name}"))?;
    ensure!(
        !value.trim().is_empty(),
        "secret environment variable {name} is empty"
    );
    Ok(value)
}

pub fn read_server(path: &Path, name: &str) -> Result<Connection> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Servers {
        mcp_servers: BTreeMap<String, serde_json::Value>,
    }
    let mut data = String::new();
    File::open(path)
        .with_context(|| format!("open MCP config {}", path.display()))?
        .take(4 * 1024 * 1024 + 1)
        .read_to_string(&mut data)?;
    ensure!(
        data.len() <= 4 * 1024 * 1024,
        "MCP configuration exceeds 4 MiB"
    );
    let mut config: Servers = serde_json::from_str(&data).context("invalid mcpServers JSON")?;
    let entry = config
        .mcp_servers
        .remove(name)
        .with_context(|| format!("MCP configuration has no server named {name:?}"))?;
    if entry.get("command").is_some()
        || entry.get("transport").and_then(|v| v.as_str()) == Some("stdio")
    {
        bail!("stdio MCP servers are outside the scope of remote MCP packs");
    }
    // Interpret the same subset as the reference CLI. Other Pi keys are ignored.
    let connection = serde_json::from_value(serde_json::json!({
        "url": entry.get("url"),
        "transport": entry.get("transport").cloned().unwrap_or(serde_json::json!("http")),
        "tokenEnv": entry.get("tokenEnv"),
        "oauth": entry.get("oauth"),
    }))
    .context("invalid remote MCP server configuration")?;
    Ok(connection)
}
