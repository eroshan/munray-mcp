use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use serde_json::{Map, Value};

use crate::runtime::LuaRuntime;

#[derive(Debug)]
struct Issue {
    namespace: String,
    function: String,
    message: String,
}

impl Issue {
    fn new(ns: &str, function: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            namespace: ns.into(),
            function: function.into(),
            message: message.into(),
        }
    }
}

/// Implements the CLI validator.  It intentionally creates no durable store: the
/// runtime's default store is temporary and is dropped with this function.
pub fn run(dir: &Path) -> Result<usize> {
    println!("Validating services directory: {}", dir.display());
    let external = match fs::metadata(dir) {
        Ok(meta) if meta.is_dir() => Some(dir),
        Ok(_) => bail!("service path is not a directory: {}", dir.display()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            println!("✓ No services directory found (base APIs only)");
            None
        }
        Err(e) => {
            return Err(e)
                .with_context(|| format!("cannot inspect services directory {}", dir.display()));
        }
    };
    let packs = external
        .map(discover_packs)
        .transpose()?
        .unwrap_or_default();
    let runtime = LuaRuntime::new(external)?;
    let mut warnings = metadata_warnings(&runtime, &packs)?;
    let schemas = runtime
        .discovered_schemas()
        .context("failed to discover namespace schemas")?;
    let mut issues = Vec::new();
    for (ns, schema) in &schemas {
        structural(ns, schema, &mut issues);
    }
    for (ns, schema) in &schemas {
        semantic(&runtime, ns, schema, &schemas, &mut issues);
    }
    if !issues.is_empty() {
        eprintln!(
            "✗ Schema validation failed ({} issue(s))\n\nSchemas:\n  {} schema namespace(s) discovered\n\nIssues:",
            issues.len(),
            schemas.len()
        );
        for issue in issues {
            eprintln!(
                "- {} {}: {}",
                issue.namespace, issue.function, issue.message
            );
        }
        bail!("validation failed")
    }
    println!("✓ Services loaded successfully\n\nSchema:\n  ✓  Core (builtin)");
    let builtin: BTreeSet<_> = ["helpers", "json", "secrets", "store", "async_task"]
        .into_iter()
        .collect();
    let roots: BTreeSet<String> = schemas
        .keys()
        .filter_map(|n| n.split('.').next().map(str::to_owned))
        .collect();
    let external_roots: Vec<_> = roots
        .iter()
        .filter(|root| !builtin.contains(root.as_str()))
        .collect();
    if external_roots.is_empty() {
        println!("\nNo external services found");
    } else {
        for root in &external_roots {
            println!("  ✓  {root}");
        }
        println!("\nUser service(s):");
        for root in &external_roots {
            println!("  •  {root}");
        }
    }
    let internal: Vec<_> = roots
        .iter()
        .filter(|root| builtin.contains(root.as_str()))
        .collect();
    if !internal.is_empty() {
        println!("\nInternal services:");
        for root in internal {
            println!("  •  {root}");
        }
    }
    if !warnings.is_empty() {
        warnings.sort();
        warnings.dedup();
        println!("\nWarnings:");
        for warning in warnings {
            println!("  •  {warning}");
        }
    }
    Ok(packs.len())
}

fn discover_packs(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut packs = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        if !entry.file_name().to_string_lossy().starts_with('.')
            && entry.path().is_dir()
            && entry.path().join("src").is_dir()
        {
            packs.push(entry.path());
        }
    }
    packs.sort();
    Ok(packs)
}

fn metadata_warnings(runtime: &LuaRuntime, packs: &[PathBuf]) -> Result<Vec<String>> {
    let mut out = Vec::new();
    for pack in packs {
        let name = pack.file_name().unwrap_or_default().to_string_lossy();
        if let Some(v) = runtime.global_field_json(&name, "__intro")? {
            if !v.is_string() {
                out.push(format!("{name}: __intro must be a string"));
            }
        }
        let mut allowed = Vec::new();
        if let Some(v) = runtime.global_field_json(&name, "__allowed_cli_commands")? {
            match v.as_array() {
                Some(values) => {
                    for value in values {
                        match value.as_str().map(str::trim) {
                            Some(s) if !s.is_empty() => allowed.push(s.to_owned()),
                            _ => out.push(format!(
                                "{name}: __allowed_cli_commands must contain strings"
                            )),
                        }
                    }
                }
                None => out.push(format!(
                    "{name}: __allowed_cli_commands must be an array of strings"
                )),
            }
        }
        let mut uses_cli = false;
        for entry in walkdir::WalkDir::new(pack.join("src")).follow_links(true) {
            let entry = entry?;
            if entry.file_type().is_file() && entry.path().extension().is_some_and(|x| x == "lua") {
                let text = fs::read_to_string(entry.path())?;
                uses_cli |= text.contains("sys.cli.")
                    || text.contains("sys.blob.from_cli")
                    || text.contains("sys.secrets.command");
            }
        }
        if uses_cli && allowed.is_empty() {
            out.push(format!(
                "{name}: service uses CLI primitives without declaring __allowed_cli_commands"
            ));
        }
    }
    Ok(out)
}

fn object<'a>(v: &'a Value) -> Option<&'a Map<String, Value>> {
    v.as_object()
}
fn nonblank(v: Option<&Value>) -> bool {
    v.and_then(Value::as_str)
        .is_some_and(|s| !s.trim().is_empty())
}
fn issue(issues: &mut Vec<Issue>, ns: &str, path: &str, msg: impl Into<String>) {
    issues.push(Issue::new(ns, "/", format!("{path}: {}", msg.into())));
}

// This mirrors the checked-in JSON schema, while retaining every independent
// leaf failure instead of rejecting deserialization at the first bad field.
fn structural(ns: &str, schema: &Value, issues: &mut Vec<Issue>) {
    let Some(o) = object(schema) else {
        issue(issues, ns, "/", "must be an object");
        return;
    };
    let allowed = [
        "namespace",
        "service",
        "summary",
        "description",
        "deprecated",
        "functions",
        "resources",
        "types",
        "examples",
        "usage_hint",
    ];
    for key in o.keys().filter(|k| !allowed.contains(&k.as_str())) {
        issue(issues, ns, &format!("/{key}"), "unknown property");
    }
    for key in ["namespace", "service", "functions"] {
        if !o.contains_key(key) {
            issue(
                issues,
                ns,
                "/",
                format!("missing required property `{key}`"),
            );
        }
    }
    for key in ["namespace", "service"] {
        if !nonblank(o.get(key)) {
            issue(issues, ns, &format!("/{key}"), "must be a non-empty string");
        }
    }
    for key in ["summary", "description", "examples"] {
        if o.contains_key(key) && !o[key].is_string() {
            issue(issues, ns, &format!("/{key}"), "must be a string");
        }
    }
    if o.contains_key("usage_hint") {
        if !o["usage_hint"].is_string() {
            issue(issues, ns, "/usage_hint", "must be a string");
        } else if ns.contains('.') {
            issue(
                issues,
                ns,
                "/usage_hint",
                "is allowed only on top-level namespaces",
            );
        }
    }
    if o.contains_key("deprecated") && !o["deprecated"].is_boolean() {
        issue(issues, ns, "/deprecated", "must be a boolean");
    }
    if let Some(functions) = o.get("functions").and_then(Value::as_array) {
        for (i, f) in functions.iter().enumerate() {
            structural_function(ns, i, f, issues);
        }
    } else {
        issue(issues, ns, "/functions", "must be an array");
    }
    if let Some(resources) = o.get("resources") {
        match resources.as_array() {
            Some(a) => {
                for (i, v) in a.iter().enumerate() {
                    if !nonblank(Some(v)) {
                        issue(
                            issues,
                            ns,
                            &format!("/resources/{i}"),
                            "must be a non-empty string",
                        );
                    }
                }
            }
            None => issue(issues, ns, "/resources", "must be an array"),
        }
    }
    if let Some(types) = o.get("types") {
        match object(types) {
            Some(types) => {
                for (name, def) in types {
                    let Some(d) = object(def) else {
                        issue(issues, ns, &format!("/types/{name}"), "must be an object");
                        continue;
                    };
                    if d.keys().any(|k| k != "description" && k != "shape") {
                        issue(issues, ns, &format!("/types/{name}"), "unknown property");
                    }
                    if !d.get("description").is_some_and(Value::is_string)
                        && !d.get("shape").is_some_and(Value::is_string)
                    {
                        issue(
                            issues,
                            ns,
                            &format!("/types/{name}"),
                            "must contain description or shape string",
                        );
                    }
                }
            }
            None => issue(issues, ns, "/types", "must be an object"),
        }
    }
}

fn structural_function(ns: &str, i: usize, value: &Value, issues: &mut Vec<Issue>) {
    let p = format!("/functions/{i}");
    let Some(f) = object(value) else {
        issue(issues, ns, &p, "must be an object");
        return;
    };
    let allowed = [
        "name",
        "signature",
        "returns_contract",
        "description",
        "summary",
        "deprecated",
        "mutating",
        "guarded",
        "returns_typed",
        "yields",
        "params",
        "async",
        "examples",
        "origin",
    ];
    for k in f.keys().filter(|k| !allowed.contains(&k.as_str())) {
        issue(issues, ns, &format!("{p}/{k}"), "unknown property");
    }
    for k in [
        "name",
        "signature",
        "returns_contract",
        "description",
        "guarded",
        "returns_typed",
    ] {
        if !f.contains_key(k) {
            issue(issues, ns, &p, format!("missing required property `{k}`"));
        }
    }
    if !nonblank(f.get("name")) {
        issue(
            issues,
            ns,
            &format!("{p}/name"),
            "must be a non-empty string",
        );
    }
    let sig = f.get("signature").and_then(Value::as_str);
    if !sig.is_some_and(|s| !s.is_empty() && s.starts_with('(') && s.ends_with(')')) {
        issue(
            issues,
            ns,
            &format!("{p}/signature"),
            "must match ^\\(.*\\)$",
        );
    }
    if !matches!(
        f.get("returns_contract").and_then(Value::as_str),
        Some("core.result" | "core.iter" | "core.async.result")
    ) {
        issue(
            issues,
            ns,
            &format!("{p}/returns_contract"),
            "must be a supported return contract",
        );
    }
    if !f.get("description").is_some_and(Value::is_string) {
        issue(issues, ns, &format!("{p}/description"), "must be a string");
    }
    if !f.get("guarded").is_some_and(Value::is_boolean) {
        issue(issues, ns, &format!("{p}/guarded"), "must be a boolean");
    }
    if !f.get("returns_typed").is_some_and(Value::is_array)
        || f.get("returns_typed")
            .and_then(Value::as_array)
            .is_some_and(Vec::is_empty)
    {
        issue(
            issues,
            ns,
            &format!("{p}/returns_typed"),
            "must be a non-empty array",
        );
    }
    if f.get("returns_contract").and_then(Value::as_str) == Some("core.iter")
        && !nonblank(f.get("yields"))
    {
        issue(
            issues,
            ns,
            &format!("{p}/yields"),
            "is required for core.iter",
        );
    }
    if let Some(params) = f.get("params").and_then(Value::as_array) {
        for (index, param) in params.iter().enumerate() {
            structural_param(ns, &format!("{p}/params/{index}"), param, true, issues);
        }
    } else if f.contains_key("params") {
        issue(issues, ns, &format!("{p}/params"), "must be an array");
    }
    if let Some(returns) = f.get("returns_typed").and_then(Value::as_array) {
        for (index, returned) in returns.iter().enumerate() {
            structural_return(ns, &format!("{p}/returns_typed/{index}"), returned, issues);
        }
    }
    if f.get("returns_contract").and_then(Value::as_str) == Some("core.async.result")
        && !f.get("async").is_some_and(Value::is_object)
    {
        issue(
            issues,
            ns,
            &format!("{p}/async"),
            "is required for core.async.result",
        );
    }
}

fn structural_param(ns: &str, path: &str, value: &Value, named: bool, issues: &mut Vec<Issue>) {
    let Some(o) = object(value) else {
        issue(issues, ns, path, "must be an object");
        return;
    };
    let allowed: &[&str] = if named {
        &["name", "type", "optional", "description", "schema"]
    } else {
        &["type", "optional", "description", "schema"]
    };
    for key in o.keys().filter(|key| !allowed.contains(&key.as_str())) {
        issue(issues, ns, &format!("{path}/{key}"), "unknown property");
    }
    if named && !nonblank(o.get("name")) {
        issue(
            issues,
            ns,
            &format!("{path}/name"),
            "must be a non-empty string",
        );
    }
    if !nonblank(o.get("type")) {
        issue(
            issues,
            ns,
            &format!("{path}/type"),
            "must be a non-empty string",
        );
    }
    if o.contains_key("optional") && !o["optional"].is_boolean() {
        issue(issues, ns, &format!("{path}/optional"), "must be a boolean");
    }
    if o.contains_key("description") && !o["description"].is_string() {
        issue(
            issues,
            ns,
            &format!("{path}/description"),
            "must be a string",
        );
    }
    if let Some(fields) = o.get("schema") {
        match object(fields) {
            Some(fields) => {
                for (name, field) in fields {
                    structural_param(ns, &format!("{path}/schema/{name}"), field, false, issues);
                }
            }
            None => issue(issues, ns, &format!("{path}/schema"), "must be an object"),
        }
    }
}

fn structural_return(ns: &str, path: &str, value: &Value, issues: &mut Vec<Issue>) {
    let Some(o) = object(value) else {
        issue(issues, ns, path, "must be an object");
        return;
    };
    for key in o
        .keys()
        .filter(|key| !["name", "type", "description", "schema"].contains(&key.as_str()))
    {
        issue(issues, ns, &format!("{path}/{key}"), "unknown property");
    }
    for key in ["name", "type"] {
        if !nonblank(o.get(key)) {
            issue(
                issues,
                ns,
                &format!("{path}/{key}"),
                "must be a non-empty string",
            );
        }
    }
    for key in ["description", "schema"] {
        if o.contains_key(key) && !o[key].is_string() {
            issue(issues, ns, &format!("{path}/{key}"), "must be a string");
        }
    }
}

fn semantic(
    runtime: &LuaRuntime,
    ns: &str,
    schema: &Value,
    schemas: &BTreeMap<String, Value>,
    issues: &mut Vec<Issue>,
) {
    let Some(s) = object(schema) else { return };
    if nonblank(s.get("namespace")) && s["namespace"].as_str() != Some(ns) {
        issues.push(Issue::new(
            ns,
            "/",
            "declared namespace does not match discovered path",
        ));
    }
    if s.get("service").and_then(Value::as_str) == Some(ns) {
        if let Some(resources) = s.get("resources").and_then(Value::as_array) {
            for r in resources {
                if let Some(r) = r.as_str() {
                    if !r.starts_with(&format!("{ns}.")) {
                        issues.push(Issue::new(
                            ns,
                            "/",
                            format!("resource `{r}` must begin with `{ns}.`"),
                        ));
                    }
                    if !schemas.contains_key(r) {
                        issues.push(Issue::new(
                            ns,
                            "/",
                            format!("resource `{r}` is not a discovered schema"),
                        ));
                    }
                }
            }
        }
    }
    let types = s.get("types").and_then(Value::as_object);
    for f in s
        .get("functions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(f) = object(f) else { continue };
        let name = f.get("name").and_then(Value::as_str).unwrap_or("?");
        let full = format!("{ns}.{name}");
        if let Ok(false) = runtime.is_callable_path(&full) {
            issues.push(Issue::new(ns, &full, "declared function is not callable"));
        }
        contract(ns, &full, f, issues);
        for ty in type_fields(f) {
            check_type(ns, &full, ty, types, issues);
        }
    }
}
fn contract(ns: &str, full: &str, f: &Map<String, Value>, out: &mut Vec<Issue>) {
    let empty = Vec::new();
    let returns = f
        .get("returns_typed")
        .and_then(Value::as_array)
        .unwrap_or(&empty);
    let c = f.get("returns_contract").and_then(Value::as_str);
    let err = |v: &Value| {
        object(v).is_some_and(|o| {
            o.get("name").and_then(Value::as_str) == Some("err")
                && o.get("type").and_then(Value::as_str) == Some("core.error|nil")
        })
    };
    match c {
        Some("core.result")
            if returns.len() != 2
                || !returns.first().is_some_and(|v| {
                    object(v).is_some_and(|o| nonblank(o.get("name")) && nonblank(o.get("type")))
                })
                || !returns.get(1).is_some_and(err) =>
        {
            out.push(Issue::new(
                ns,
                full,
                "core.result must return value and {name: err, type: core.error|nil}",
            ))
        }
        Some("core.iter")
            if returns.len() != 1
                || !returns.first().is_some_and(|v| {
                    object(v)
                        .is_some_and(|o| o.get("type").and_then(Value::as_str) == Some("Iterator"))
                })
                || !nonblank(f.get("yields")) =>
        {
            out.push(Issue::new(
                ns,
                full,
                "core.iter must return one Iterator and declare yields",
            ))
        }
        Some("core.async.result") => {
            let a = f.get("async").and_then(object);
            let handle = a.and_then(|a| a.get("handle")).and_then(Value::as_str);
            if a.and_then(|a| a.get("kind")).and_then(Value::as_str) != Some("task")
                || handle.is_none_or(str::is_empty)
                || returns.len() != 2
                || !returns.first().is_some_and(|v| {
                    object(v).is_some_and(|o| {
                        o.get("name").and_then(Value::as_str) == handle
                            && o.get("type").and_then(Value::as_str) == Some("string")
                    })
                })
                || !returns.get(1).is_some_and(err)
            {
                out.push(Issue::new(ns, full, "invalid core.async.result contract"));
            }
        }
        _ => {}
    }
}
fn type_fields<'a>(f: &'a Map<String, Value>) -> Vec<&'a str> {
    let mut v = Vec::new();
    for k in ["yields"] {
        if let Some(x) = f.get(k).and_then(Value::as_str) {
            v.push(x)
        }
    }
    for p in f
        .get("params")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(o) = object(p) {
            if let Some(x) = o.get("type").and_then(Value::as_str) {
                v.push(x)
            }
            if let Some(fields) = o.get("schema").and_then(object) {
                for x in fields.values() {
                    if let Some(x) = object(x)
                        .and_then(|x| x.get("type"))
                        .and_then(Value::as_str)
                    {
                        v.push(x)
                    }
                }
            }
        }
    }
    for r in f
        .get("returns_typed")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        if let Some(x) = object(r)
            .and_then(|x| x.get("type"))
            .and_then(Value::as_str)
        {
            v.push(x)
        }
    }
    v
}
fn check_type(
    ns: &str,
    full: &str,
    ty: &str,
    types: Option<&Map<String, Value>>,
    out: &mut Vec<Issue>,
) {
    for b in ty.split('|') {
        let mut t = b
            .trim()
            .split_whitespace()
            .next()
            .unwrap_or("")
            .trim_end_matches('?');
        while let Some(x) = t.strip_suffix("[]") {
            t = x
        }
        if !t.contains('.')
            && is_ident(t)
            && !matches!(
                t,
                "string" | "number" | "boolean" | "table" | "any" | "Iterator" | "nil" | "function"
            )
            && !t.starts_with("core.")
            && !types.is_some_and(|x| x.contains_key(t))
        {
            out.push(Issue::new(
                ns,
                full,
                format!("type `{t}` is not declared locally"),
            ));
        }
    }
}
fn is_ident(s: &str) -> bool {
    let mut c = s.chars();
    matches!(c.next(),Some(x)if x.is_ascii_alphabetic()||x=='_')
        && c.all(|x| x.is_ascii_alphanumeric() || x == '_')
}
