//! Machine-readable metadata and renderers for the internal `sys.*` API.
//!
//! Runtime reflection supplies the set of registered functions.  This module
//! supplies the semantic information that Lua function values cannot expose.

use std::collections::{BTreeMap, BTreeSet};

use serde::Serialize;

#[derive(Clone, Copy)]
struct FunctionMeta {
    namespace: &'static str,
    name: &'static str,
    signature: &'static str,
    description: &'static str,
}

macro_rules! sys_fn {
    ($namespace:literal, $name:literal, $signature:literal, $description:literal) => {
        FunctionMeta {
            namespace: $namespace,
            name: $name,
            signature: $signature,
            description: $description,
        }
    };
}

#[derive(Clone, Copy)]
struct NamespaceMeta {
    path: &'static str,
    summary: &'static str,
    description: &'static str,
}

const NAMESPACES: &[NamespaceMeta] = &[
    NamespaceMeta {
        path: "sys",
        summary: "Runtime helpers",
        description: "Internal primitives for trusted service-pack wrappers. Public pack functions must declare schemas; MCP session scripts never receive sys. Unless documented as an iterator, calls return a result plus a structured error; always check the error.",
    },
    NamespaceMeta {
        path: "sys.auth",
        summary: "Authentication",
        description: "Build opaque AuthRef values from SecretRef values and pass them only to HTTP or GraphQL transport options.",
    },
    NamespaceMeta {
        path: "sys.blob",
        summary: "Blob helpers",
        description: "Opaque binary handles. Blob bytes never become Lua strings; write them with sys.vfs.write_blob. Captures default to 200 MiB and share a 512 MiB runtime quota.",
    },
    NamespaceMeta {
        path: "sys.cli",
        summary: "CLI execution",
        description: "Only invoke binaries declared in <service>.__allowed_cli_commands. opts supports timeout (seconds) and cwd; caller deadlines still take precedence.",
    },
    NamespaceMeta {
        path: "sys.graphql",
        summary: "GraphQL requests",
        description: "GraphQL transport for schema-backed wrappers. opts supports path, variables, operation_name, headers, auth, and response_mode.",
    },
    NamespaceMeta {
        path: "sys.http",
        summary: "HTTP requests",
        description: "JSON HTTP transport for schema-backed wrappers. opts supports query, headers, auth, body, and pagination for list; caller deadlines apply end-to-end.",
    },
    NamespaceMeta {
        path: "sys.ingest",
        summary: "Ingested text",
        description: "Read UTF-8 text uploaded into the current MCP session through munray ingest. Tokens are runtime-local.",
    },
    NamespaceMeta {
        path: "sys.kv",
        summary: "Durable key-value storage",
        description: "Core raw durable storage. Service packs should normally use the schema-backed kv namespace with service-specific keys and expiry where appropriate.",
    },
    NamespaceMeta {
        path: "sys.secrets",
        summary: "Secret references",
        description: "Create opaque SecretRef values. Never print or return credentials; resolve them only by passing AuthRef values to transports.",
    },
    NamespaceMeta {
        path: "sys.snippets",
        summary: "Persisted snippets",
        description: "Core-managed snippet persistence. Service packs normally do not call these primitives.",
    },
    NamespaceMeta {
        path: "sys.task",
        summary: "Background tasks",
        description: "Raw task controls. Service packs should use async_task status, result, wait, and cancel after starting transport work.",
    },
    NamespaceMeta {
        path: "sys.test",
        summary: "Test helpers",
        description: "Available only for local validation and service-pack tests; never use in production pack operations.",
    },
    NamespaceMeta {
        path: "sys.url",
        summary: "URL helpers",
        description: "Escape individual query values or path components before composing request paths; do not escape whole URLs.",
    },
    NamespaceMeta {
        path: "sys.vfs",
        summary: "Virtual filesystem",
        description: "Runtime-local scratch storage. Paths must be safe relative VFS paths; guarded mutations are determined by the enclosing public schema wrapper.",
    },
];

// This is the machine-readable metadata used by `sys list`. Reflection below
// remains authoritative for actual availability; tests enforce path parity.
const FUNCTIONS: &[FunctionMeta] = &[
    sys_fn!(
        "sys",
        "exec_mode",
        "exec_mode() → string",
        "Return the current execution mode."
    ),
    sys_fn!(
        "sys.auth",
        "basic",
        "basic(user_ref SecretRef, pass_ref SecretRef) → AuthRef",
        "Create Basic authentication credentials from secret references."
    ),
    sys_fn!(
        "sys.auth",
        "bearer",
        "bearer(token_ref SecretRef) → AuthRef",
        "Create Bearer authentication credentials from a secret reference."
    ),
    sys_fn!(
        "sys.blob",
        "from_cli",
        "from_cli(tool string, args table, opts? table) → blob",
        "Capture stdout bytes from a CLI invocation."
    ),
    sys_fn!(
        "sys.blob",
        "from_http",
        "from_http(method string, base_url string, path string, opts? table) → blob",
        "Capture response-body bytes from an HTTP request."
    ),
    sys_fn!(
        "sys.blob",
        "len",
        "len(blob blob) → int",
        "Return the blob length in bytes."
    ),
    sys_fn!(
        "sys.cli",
        "json",
        "json(tool string, args table, opts? table) → value",
        "Run a CLI command and parse stdout as JSON."
    ),
    sys_fn!(
        "sys.cli",
        "start_json",
        "start_json(tool string, args table, opts? table) → task_id",
        "Start a CLI JSON command as a background task."
    ),
    sys_fn!(
        "sys.cli",
        "start_text",
        "start_text(tool string, args table, opts? table) → task_id",
        "Start a CLI text command as a background task."
    ),
    sys_fn!(
        "sys.cli",
        "text",
        "text(tool string, args table, opts? table) → string",
        "Run a CLI command and return stdout as text."
    ),
    sys_fn!(
        "sys.graphql",
        "list",
        "list(base_url string, document string, opts table) → iterator",
        "Iterate paginated GraphQL results."
    ),
    sys_fn!(
        "sys.graphql",
        "request",
        "request(base_url string, document string, opts? table) → table",
        "Execute a GraphQL request."
    ),
    sys_fn!(
        "sys.graphql",
        "start_request",
        "start_request(base_url string, document string, opts? table) → task_id",
        "Start a GraphQL request as a background task."
    ),
    sys_fn!(
        "sys.http",
        "list",
        "list(method string, base_url string, path string, opts table) → iterator",
        "Iterate paginated HTTP results."
    ),
    sys_fn!(
        "sys.http",
        "request",
        "request(method string, base_url string, path string, opts? table) → table",
        "Execute an HTTP request and decode its JSON response."
    ),
    sys_fn!(
        "sys.http",
        "start_request",
        "start_request(method string, base_url string, path string, opts? table) → task_id",
        "Start an HTTP request as a background task."
    ),
    sys_fn!(
        "sys.ingest",
        "get",
        "get(token string) → string",
        "Read text previously uploaded into this runtime."
    ),
    sys_fn!(
        "sys.kv",
        "clear",
        "clear(namespace string) → boolean",
        "Delete every value in a durable namespace."
    ),
    sys_fn!(
        "sys.kv",
        "delete",
        "delete(namespace string, key string) → boolean",
        "Delete a durable value."
    ),
    sys_fn!(
        "sys.kv",
        "get",
        "get(namespace string, key string) → value",
        "Read a durable value."
    ),
    sys_fn!(
        "sys.kv",
        "keys",
        "keys(namespace string) → table",
        "List durable keys in a namespace."
    ),
    sys_fn!(
        "sys.kv",
        "len",
        "len(namespace string) → int",
        "Count durable values in a namespace."
    ),
    sys_fn!(
        "sys.kv",
        "put",
        "put(namespace string, key string, value any, opts? table) → boolean",
        "Store a durable value."
    ),
    sys_fn!(
        "sys.secrets",
        "command",
        "command(spec table) → SecretRef",
        "Create a command-backed secret reference."
    ),
    sys_fn!(
        "sys.secrets",
        "env",
        "env(name string) → SecretRef",
        "Create an environment-backed secret reference."
    ),
    sys_fn!(
        "sys.snippets",
        "delete",
        "delete(path string) → boolean",
        "Delete a persisted snippet."
    ),
    sys_fn!(
        "sys.snippets",
        "get",
        "get(path string) → table",
        "Read a persisted snippet definition."
    ),
    sys_fn!(
        "sys.snippets",
        "list",
        "list() → table",
        "List persisted snippet definitions."
    ),
    sys_fn!(
        "sys.snippets",
        "save",
        "save(definition table) → boolean",
        "Save and install a persisted snippet."
    ),
    sys_fn!(
        "sys.task",
        "cancel",
        "cancel(task_id string) → boolean",
        "Cancel a background task."
    ),
    sys_fn!(
        "sys.task",
        "result",
        "result(task_id string) → value",
        "Return a completed task result without waiting."
    ),
    sys_fn!(
        "sys.task",
        "status",
        "status(task_id string) → table",
        "Return a background task status."
    ),
    sys_fn!(
        "sys.task",
        "wait",
        "wait(task_id string, timeout_ms? int) → value",
        "Wait for a background task result."
    ),
    sys_fn!(
        "sys.test",
        "set_mode",
        "set_mode(mode string) → boolean",
        "Set execution mode for tests."
    ),
    sys_fn!(
        "sys.test",
        "start_task",
        "start_task(delay_ms int, result any) → task_id",
        "Start a synthetic task for tests."
    ),
    sys_fn!(
        "sys.url",
        "path_escape",
        "path_escape(value string) → string",
        "Percent-encode a URL path component."
    ),
    sys_fn!(
        "sys.url",
        "path_unescape",
        "path_unescape(value string) → string",
        "Decode a percent-encoded URL path component."
    ),
    sys_fn!(
        "sys.url",
        "query_escape",
        "query_escape(value string) → string",
        "Percent-encode a value for use in a URL query string."
    ),
    sys_fn!(
        "sys.url",
        "query_unescape",
        "query_unescape(value string) → string",
        "Decode a percent-encoded URL query value."
    ),
    sys_fn!(
        "sys.vfs",
        "expose",
        "expose(paths table) → table",
        "Expose VFS files as temporary host copies."
    ),
    sys_fn!(
        "sys.vfs",
        "list",
        "list(path string, opts? table) → table",
        "List VFS directory entries."
    ),
    sys_fn!(
        "sys.vfs",
        "mkdirp",
        "mkdirp(path string) → boolean",
        "Create VFS directories."
    ),
    sys_fn!(
        "sys.vfs",
        "read_text",
        "read_text(path string, opts? table) → string",
        "Read a UTF-8 VFS file."
    ),
    sys_fn!(
        "sys.vfs",
        "remove",
        "remove(path string) → boolean",
        "Remove a VFS file or directory."
    ),
    sys_fn!(
        "sys.vfs",
        "stat",
        "stat(path string) → table",
        "Return VFS file metadata."
    ),
    sys_fn!(
        "sys.vfs",
        "to_text",
        "to_text(path string, opts? table) → table",
        "Extract text previews from a VFS artifact."
    ),
    sys_fn!(
        "sys.vfs",
        "write_blob",
        "write_blob(path string, blob blob, opts? table) → table",
        "Write blob bytes to the VFS."
    ),
    sys_fn!(
        "sys.vfs",
        "write_text",
        "write_text(path string, text string, opts? table) → table",
        "Write UTF-8 text to the VFS."
    ),
];

#[derive(Debug, Clone, Serialize)]
pub struct SysList {
    pub version: u8,
    pub namespaces: Vec<SysNamespace>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SysNamespace {
    pub path: String,
    pub summary: String,
    pub description: String,
    pub functions: Vec<SysFunction>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SysFunction {
    pub path: String,
    pub name: String,
    pub signature: String,
    pub description: String,
    pub documented: bool,
}

pub fn build(reflected: Vec<(String, Vec<String>)>) -> SysList {
    let metadata = FUNCTIONS
        .iter()
        .map(|item| ((item.namespace, item.name), item))
        .collect::<BTreeMap<_, _>>();
    let namespace_metadata = NAMESPACES
        .iter()
        .map(|item| (item.path, item))
        .collect::<BTreeMap<_, _>>();
    let mut namespaces = Vec::new();

    for (namespace, functions) in reflected {
        let mut entries = functions
            .into_iter()
            .map(|name| {
                let path = format!("{namespace}.{name}");
                if let Some(meta) = metadata.get(&(namespace.as_str(), name.as_str())).copied() {
                    SysFunction {
                        path,
                        name,
                        signature: meta.signature.to_owned(),
                        description: meta.description.to_owned(),
                        documented: true,
                    }
                } else {
                    SysFunction {
                        signature: format!("{name}(...)"),
                        path,
                        name,
                        description: "Undocumented system primitive.".to_owned(),
                        documented: false,
                    }
                }
            })
            .collect::<Vec<_>>();
        entries.sort_by(|left, right| left.name.cmp(&right.name));
        let meta = namespace_metadata.get(namespace.as_str()).copied();
        namespaces.push(SysNamespace {
            summary: meta
                .map(|item| item.summary)
                .unwrap_or("System helpers")
                .to_owned(),
            description: meta
                .map(|item| item.description)
                .unwrap_or("No documentation is available for this system namespace.")
                .to_owned(),
            path: namespace,
            functions: entries,
        });
    }
    namespaces.sort_by(|left, right| left.path.cmp(&right.path));
    SysList {
        version: 1,
        namespaces,
    }
}

pub fn undocumented_paths(reflected: &[(String, Vec<String>)]) -> BTreeSet<String> {
    let documented = FUNCTIONS
        .iter()
        .map(|item| format!("{}.{}", item.namespace, item.name))
        .collect::<BTreeSet<_>>();
    reflected
        .iter()
        .flat_map(|(namespace, functions)| {
            functions
                .iter()
                .map(move |name| format!("{namespace}.{name}"))
        })
        .filter(|path| !documented.contains(path))
        .collect()
}

pub fn stale_paths(reflected: &[(String, Vec<String>)]) -> BTreeSet<String> {
    let reflected = reflected
        .iter()
        .flat_map(|(namespace, functions)| {
            functions
                .iter()
                .map(move |name| format!("{namespace}.{name}"))
        })
        .collect::<BTreeSet<_>>();
    FUNCTIONS
        .iter()
        .map(|item| format!("{}.{}", item.namespace, item.name))
        .filter(|path| !reflected.contains(path))
        .collect()
}

pub fn render_text(list: &SysList, width: usize) -> String {
    let width = width.max(16);
    let mut out = String::new();
    for (namespace_index, namespace) in list.namespaces.iter().enumerate() {
        if namespace_index != 0 {
            out.push('\n');
        }
        out.push_str(&namespace.path);
        out.push_str("\n    ");
        out.push_str(&namespace.summary);
        out.push('\n');
        for line in wrap(&namespace.description, width.saturating_sub(4).max(1)) {
            out.push_str("    ");
            out.push_str(&line);
            out.push('\n');
        }
        out.push('\n');
        for (function_index, function) in namespace.functions.iter().enumerate() {
            out.push_str("    ");
            out.push_str(&text_signature(&function.signature));
            out.push('\n');
            for line in wrap(&function.description, width.saturating_sub(8).max(1)) {
                out.push_str("        ");
                out.push_str(&line);
                out.push('\n');
            }
            if function_index + 1 != namespace.functions.len() {
                out.push('\n');
            }
        }
    }
    out
}

pub fn render_markdown(list: &SysList) -> String {
    let mut out = String::new();
    for (index, namespace) in list.namespaces.iter().enumerate() {
        if index != 0 {
            out.push('\n');
        }
        out.push_str(&format!(
            "## `{}` — {}\n\n",
            namespace.path, namespace.summary
        ));
        out.push_str(&format!("{}\n\n", namespace.description));
        out.push_str("| Function | Description |\n|---|---|\n");
        for function in &namespace.functions {
            out.push_str(&format!(
                "| `{}` | {} |\n",
                function.signature, function.description
            ));
        }
    }
    out
}

fn text_signature(signature: &str) -> String {
    signature.replace(" → ", " -> ")
}

fn display_width(value: &str) -> usize {
    value.chars().count()
}

fn wrap(value: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut line = String::new();
    for word in value.split_whitespace() {
        let next_width = display_width(&line) + usize::from(!line.is_empty()) + display_width(word);
        if !line.is_empty() && next_width > width {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_output_aligns_wrapped_descriptions() {
        let list = SysList {
            version: 1,
            namespaces: vec![SysNamespace {
                path: "sys.demo".to_owned(),
                summary: "Demo helpers".to_owned(),
                description: "A compact example namespace.".to_owned(),
                functions: vec![SysFunction {
                    path: "sys.demo.example".to_owned(),
                    name: "example".to_owned(),
                    signature: "example(value string) → blob".to_owned(),
                    description: "Create a value from a deliberately long description.".to_owned(),
                    documented: true,
                }],
            }],
        };
        assert_eq!(
            render_text(&list, 30),
            "sys.demo\n    Demo helpers\n    A compact example\n    namespace.\n\n    example(value string) -> blob\n        Create a value from a\n        deliberately long\n        description.\n"
        );
    }
}
