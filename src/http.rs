use std::{
    io::Read,
    sync::OnceLock,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{Engine, engine::general_purpose::STANDARD};
use mlua::{Lua, LuaSerdeExt, Table, Value};
use reqwest::{Method, Url, blocking::Client};
use serde_json::{Map, Value as JsonValue, json};

use crate::runtime::lua_error;

const DEFAULT_JSON_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const MAX_JSON_RESPONSE_BYTES: usize = 64 * 1024 * 1024;

/// A process-wide reqwest client owns the connection pool. Per-request timeouts
/// are set on RequestBuilder, so pooling never leaks a prior request's deadline.
fn client() -> Result<&'static Client, TransportError> {
    static CLIENT: OnceLock<Result<Client, String>> = OnceLock::new();
    match CLIENT.get_or_init(|| Client::builder().build().map_err(|error| error.to_string())) {
        Ok(client) => Ok(client),
        Err(error) => Err(http_error(error)),
    }
}

pub(crate) fn register(lua: &Lua, raw: &Table, tasks: crate::tasks::Manager) -> mlua::Result<()> {
    let http: Table = raw.get("http")?;
    http.set(
        "request",
        lua.create_function(
            |lua, (method, base_url, path, opts): (String, String, String, Option<Table>)| {
                let opts = options(lua, opts)?;
                match request(&method, &base_url, &path, &opts) {
                    Ok(value) => Ok((lua.to_value(&value)?, Value::Nil)),
                    Err(error) => lua_error(lua, &error.code, error.message, error.recoverable),
                }
            },
        )?,
    )?;
    http.set(
        "list",
        lua.create_function(
            |lua, (method, base_url, path, opts): (String, String, String, Table)| {
                let opts = options(lua, Some(opts))?;
                let mut state = HttpListState::new(method, base_url, path, opts)
                    .map_err(mlua::Error::external)?;
                lua.create_function_mut(move |lua, ()| match state.next() {
                    Ok(Some((item, meta))) => Ok((lua.to_value(&item)?, lua.to_value(&meta)?)),
                    Ok(None) => Ok((Value::Nil, Value::Nil)),
                    Err(error) => Err(mlua::Error::external(error.message)),
                })
            },
        )?,
    )?;
    let http_tasks = tasks.clone();
    http.set(
        "start_request",
        lua.create_function(
            move |lua, (method, base_url, path, opts): (String, String, String, Option<Table>)| {
                let opts = options(lua, opts)?;
                match http_tasks.start(move |cancellation| {
                    request_cancellable(&method, &base_url, &path, &opts, Some(&cancellation))
                        .map_err(|error| {
                            crate::tasks::TaskFailure::new(
                                error.code,
                                error.message,
                                error.recoverable,
                            )
                        })
                }) {
                    Ok(id) => Ok((Value::String(lua.create_string(&id)?), Value::Nil)),
                    Err(error) => lua_error(lua, "TOO_MANY_TASKS", error, true),
                }
            },
        )?,
    )?;

    let graphql: Table = raw.get("graphql")?;
    graphql.set(
        "request",
        lua.create_function(
            |lua, (base_url, document, opts): (String, String, Option<Table>)| {
                let opts = options(lua, opts)?;
                match graphql_request(&base_url, &document, opts) {
                    Ok(value) => Ok((lua.to_value(&value)?, Value::Nil)),
                    Err(error) => lua_error(lua, &error.code, error.message, error.recoverable),
                }
            },
        )?,
    )?;
    graphql.set(
        "list",
        lua.create_function(|lua, (base_url, document, opts): (String, String, Table)| {
            let opts = options(lua, Some(opts))?;
            let mut state =
                GraphqlListState::new(base_url, document, opts).map_err(mlua::Error::external)?;
            lua.create_function_mut(move |lua, ()| match state.next() {
                Ok(Some((item, meta))) => Ok((lua.to_value(&item)?, lua.to_value(&meta)?)),
                Ok(None) => Ok((Value::Nil, Value::Nil)),
                Err(error) => Err(mlua::Error::external(error.message)),
            })
        })?,
    )?;
    graphql.set(
        "start_request",
        lua.create_function(
            move |lua, (base_url, document, opts): (String, String, Option<Table>)| {
                let opts = options(lua, opts)?;
                match tasks.start(move |cancellation| {
                    graphql_request_cancellable(&base_url, &document, opts, Some(&cancellation))
                        .map_err(|error| {
                            crate::tasks::TaskFailure::new(
                                error.code,
                                error.message,
                                error.recoverable,
                            )
                        })
                }) {
                    Ok(id) => Ok((Value::String(lua.create_string(&id)?), Value::Nil)),
                    Err(error) => lua_error(lua, "TOO_MANY_TASKS", error, true),
                }
            },
        )?,
    )?;
    Ok(())
}

fn graphql_request(
    base_url: &str,
    document: &str,
    opts: Map<String, JsonValue>,
) -> Result<JsonValue, TransportError> {
    graphql_request_cancellable(base_url, document, opts, None)
}

fn graphql_request_cancellable(
    base_url: &str,
    document: &str,
    mut opts: Map<String, JsonValue>,
    cancellation: Option<&std::sync::atomic::AtomicBool>,
) -> Result<JsonValue, TransportError> {
    let path = opts
        .remove("path")
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "/graphql".to_owned());
    let response_mode = opts
        .remove("response_mode")
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "data".to_owned());
    let variables = opts.remove("variables").unwrap_or_else(|| json!({}));
    let operation_name = opts.remove("operation_name").unwrap_or(JsonValue::Null);
    opts.insert(
        "body".to_owned(),
        json!({"query":document,"variables":variables,"operationName":operation_name}),
    );
    let envelope = request_cancellable("POST", base_url, &path, &opts, cancellation)?;
    if envelope
        .get("errors")
        .is_some_and(|errors| !errors.as_array().is_none_or(Vec::is_empty))
    {
        return Err(TransportError {
            code: "GRAPHQL_ERROR".to_owned(),
            message: format!(
                "GraphQL response contained errors: {}; partial data: {}",
                envelope.get("errors").unwrap_or(&JsonValue::Null),
                envelope.get("data").unwrap_or(&JsonValue::Null)
            ),
            recoverable: false,
        });
    }
    if response_mode == "envelope" {
        Ok(envelope)
    } else {
        Ok(envelope.get("data").cloned().unwrap_or(JsonValue::Null))
    }
}

pub(crate) fn options(lua: &Lua, opts: Option<Table>) -> mlua::Result<Map<String, JsonValue>> {
    match opts {
        None => Ok(Map::new()),
        Some(opts) => match lua.from_value::<JsonValue>(Value::Table(opts))? {
            JsonValue::Object(map) => Ok(map),
            _ => Ok(Map::new()),
        },
    }
}

pub(crate) struct TransportError {
    pub(crate) code: String,
    pub(crate) message: String,
    pub(crate) recoverable: bool,
}

impl std::fmt::Display for TransportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::fmt::Debug for TransportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("TransportError")
            .field("code", &self.code)
            .field("message", &self.message)
            .finish()
    }
}

impl std::error::Error for TransportError {}

struct HttpListState {
    method: String,
    base_url: String,
    path: String,
    opts: Map<String, JsonValue>,
    kind: String,
    items_path: String,
    page_parameter: String,
    per_page_parameter: String,
    offset_parameter: String,
    limit_parameter: String,
    total_path: String,
    token_parameter: String,
    next_token_path: String,
    is_last_path: String,
    next_token: Option<String>,
    page: usize,
    missing_items_as_empty: bool,
    position: i64,
    per_page: usize,
    limit: usize,
    emitted: usize,
    buffer: Vec<JsonValue>,
    buffer_index: usize,
    meta: JsonValue,
    done: bool,
}

impl HttpListState {
    fn new(
        method: String,
        base_url: String,
        path: String,
        opts: Map<String, JsonValue>,
    ) -> Result<Self, TransportError> {
        let pagination = opts
            .get("pagination")
            .and_then(JsonValue::as_object)
            .ok_or_else(|| validation("pagination is required"))?;
        let kind = string_field(pagination, "kind", "");
        if !matches!(kind.as_str(), "page" | "offset" | "token" | "cursor") {
            return Err(validation(
                "pagination.kind must be 'page', 'offset', 'token', or 'cursor'",
            ));
        }
        let position = if kind == "page" {
            int_field(pagination, "start_page", 1)
        } else {
            int_field(pagination, "start_offset", 0)
        };
        Ok(Self {
            method,
            base_url,
            path,
            kind,
            items_path: string_field(pagination, "items_path", ""),
            page_parameter: string_field(pagination, "page_param", "page"),
            per_page_parameter: string_field(pagination, "per_page_param", "per_page"),
            offset_parameter: string_field(pagination, "offset_param", "offset"),
            limit_parameter: string_field(pagination, "limit_param", "limit"),
            total_path: string_field(pagination, "total_path", ""),
            token_parameter: string_field(pagination, "token_param", "nextPageToken"),
            next_token_path: string_field(pagination, "next_token_path", ""),
            is_last_path: string_field(pagination, "is_last_path", ""),
            next_token: None,
            page: 0,
            missing_items_as_empty: pagination
                .get("missing_items_as_empty")
                .and_then(JsonValue::as_bool)
                .unwrap_or(false),
            position,
            per_page: opts
                .get("per_page")
                .and_then(JsonValue::as_u64)
                .unwrap_or(20) as usize,
            limit: opts.get("limit").and_then(JsonValue::as_u64).unwrap_or(0) as usize,
            opts,
            emitted: 0,
            buffer: Vec::new(),
            buffer_index: 0,
            meta: JsonValue::Null,
            done: false,
        })
    }

    fn next(&mut self) -> Result<Option<(JsonValue, JsonValue)>, TransportError> {
        loop {
            if self.limit > 0 && self.emitted >= self.limit {
                return Ok(None);
            }
            if self.buffer_index < self.buffer.len() {
                let item = self.buffer[self.buffer_index].clone();
                self.buffer_index += 1;
                self.emitted += 1;
                return Ok(Some((item, self.meta.clone())));
            }
            if self.done {
                return Ok(None);
            }
            self.fetch()?;
        }
    }

    fn fetch(&mut self) -> Result<(), TransportError> {
        let mut opts = self.opts.clone();
        let page_start = self.position;
        let mut request_path = self.path.clone();
        if self.kind == "cursor" {
            if self.method != "GET" {
                return Err(validation("cursor-link pagination requires GET"));
            }
            self.page += 1;
            if let Some(link) = &self.next_token {
                request_path = apply_cursor_link(&self.base_url, link, &mut opts)?;
            }
            let query = opts.entry("query").or_insert_with(|| json!({}));
            let query = query
                .as_object_mut()
                .ok_or_else(|| validation("query must be a table"))?;
            query
                .entry(self.limit_parameter.clone())
                .or_insert_with(|| json!(self.per_page));
        } else if self.kind == "token" {
            self.page += 1;
            match self.method.as_str() {
                "GET" => {
                    let query = opts.entry("query").or_insert_with(|| json!({}));
                    let query = query
                        .as_object_mut()
                        .ok_or_else(|| validation("query must be a table"))?;
                    if let Some(token) = &self.next_token {
                        query.insert(self.token_parameter.clone(), json!(token));
                    }
                    query.insert(self.limit_parameter.clone(), json!(self.per_page));
                }
                "POST" => {
                    let body = opts.entry("body").or_insert_with(|| json!({}));
                    let body = body
                        .as_object_mut()
                        .ok_or_else(|| validation("body must be a table"))?;
                    if let Some(token) = &self.next_token {
                        body.insert(self.token_parameter.clone(), json!(token));
                    }
                    body.insert(self.limit_parameter.clone(), json!(self.per_page));
                }
                _ => {
                    return Err(validation(format!(
                        "unsupported method for token pagination: {}",
                        self.method
                    )));
                }
            }
        } else {
            let query = opts.entry("query").or_insert_with(|| json!({}));
            let query = query
                .as_object_mut()
                .ok_or_else(|| validation("query must be a table"))?;
            if self.kind == "page" {
                query.insert(self.page_parameter.clone(), json!(self.position));
                query.insert(self.per_page_parameter.clone(), json!(self.per_page));
            } else {
                query.insert(self.offset_parameter.clone(), json!(self.position));
                query.insert(self.limit_parameter.clone(), json!(self.per_page));
            }
        }
        let response = request(&self.method, &self.base_url, &request_path, &opts)?;
        let items = match extract_path(&response, &self.items_path).and_then(JsonValue::as_array) {
            Some(items) => items.clone(),
            None if self.missing_items_as_empty => Vec::new(),
            None => {
                return Err(validation(format!(
                    "items_path did not resolve to array: {}",
                    self.items_path
                )));
            }
        };
        if items.is_empty() {
            self.done = true;
            return Ok(());
        }
        if self.kind == "cursor" {
            self.meta = json!({"kind":"cursor","page":self.page,"per_page":self.per_page});
            self.next_token = extract_path(&response, &self.next_token_path)
                .and_then(JsonValue::as_str)
                .filter(|link| !link.is_empty())
                .map(str::to_owned);
            self.done = self.next_token.is_none();
            self.buffer = items;
            self.buffer_index = 0;
            return Ok(());
        }
        if self.kind == "token" {
            self.meta = json!({"kind":"token","page":self.page,"per_page":self.per_page});
            self.next_token = extract_path(&response, &self.next_token_path)
                .and_then(JsonValue::as_str)
                .filter(|token| !token.is_empty())
                .map(str::to_owned);
            self.done = self.next_token.is_none()
                || extract_path(&response, &self.is_last_path)
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
            self.buffer = items;
            self.buffer_index = 0;
            return Ok(());
        }
        let total = extract_path(&response, &self.total_path).and_then(JsonValue::as_i64);
        self.meta = if self.kind == "page" {
            json!({"kind":"page","page":page_start,"per_page":self.per_page})
        } else {
            json!({"kind":"offset","offset":page_start,"per_page":self.per_page,"total":total})
        };
        if self.kind == "page" {
            self.position += 1;
        } else {
            self.position += items.len() as i64;
        }
        self.done =
            items.len() < self.per_page || total.is_some_and(|total| self.position >= total);
        self.buffer = items;
        self.buffer_index = 0;
        Ok(())
    }
}

fn apply_cursor_link(
    base_url: &str,
    link: &str,
    opts: &mut Map<String, JsonValue>,
) -> Result<String, TransportError> {
    let base = Url::parse(base_url).map_err(validation)?;
    let next = match Url::parse(link) {
        Ok(url) => url,
        Err(_) => base.join(link).map_err(validation)?,
    };
    if next.scheme() != base.scheme()
        || next.host_str() != base.host_str()
        || next.port_or_known_default() != base.port_or_known_default()
    {
        return Err(validation(
            "cursor link must remain on the configured origin",
        ));
    }
    let mut query = Map::new();
    for (name, value) in next.query_pairs() {
        match query.entry(name.into_owned()) {
            serde_json::map::Entry::Vacant(entry) => {
                entry.insert(JsonValue::String(value.into_owned()));
            }
            serde_json::map::Entry::Occupied(mut entry) => match entry.get_mut() {
                JsonValue::Array(values) => values.push(JsonValue::String(value.into_owned())),
                existing => {
                    let first = std::mem::take(existing);
                    *existing =
                        JsonValue::Array(vec![first, JsonValue::String(value.into_owned())]);
                }
            },
        }
    }
    opts.insert("query".to_owned(), JsonValue::Object(query));
    let prefix = base.path().trim_end_matches('/');
    if prefix.is_empty() {
        return Ok(next.path().to_owned());
    }
    let relative = next
        .path()
        .strip_prefix(prefix)
        .ok_or_else(|| validation("cursor link escaped the configured base URL path"))?;
    if !relative.is_empty() && !relative.starts_with('/') {
        return Err(validation(
            "cursor link escaped the configured base URL path",
        ));
    }
    Ok(if relative.is_empty() {
        "/".to_owned()
    } else {
        relative.to_owned()
    })
}

struct GraphqlListState {
    base_url: String,
    document: String,
    opts: Map<String, JsonValue>,
    pagination: Map<String, JsonValue>,
    kind: String,
    page: usize,
    position: i64,
    cursor: JsonValue,
    per_page: usize,
    limit: usize,
    emitted: usize,
    buffer: Vec<JsonValue>,
    buffer_index: usize,
    meta: JsonValue,
    done: bool,
}

impl GraphqlListState {
    fn new(
        base_url: String,
        document: String,
        opts: Map<String, JsonValue>,
    ) -> Result<Self, TransportError> {
        let pagination = opts
            .get("pagination")
            .and_then(JsonValue::as_object)
            .cloned()
            .ok_or_else(|| validation("graphql.list requires pagination table"))?;
        let kind = string_field(&pagination, "kind", "");
        if !matches!(kind.as_str(), "cursor" | "offset") {
            return Err(validation("pagination.kind must be 'cursor' or 'offset'"));
        }
        Ok(Self {
            base_url,
            document,
            position: int_field(&pagination, "start_offset", 0),
            cursor: JsonValue::Null,
            page: 1,
            per_page: opts
                .get("per_page")
                .and_then(JsonValue::as_u64)
                .unwrap_or(20) as usize,
            limit: opts.get("limit").and_then(JsonValue::as_u64).unwrap_or(0) as usize,
            opts,
            pagination,
            kind,
            emitted: 0,
            buffer: Vec::new(),
            buffer_index: 0,
            meta: JsonValue::Null,
            done: false,
        })
    }

    fn next(&mut self) -> Result<Option<(JsonValue, JsonValue)>, TransportError> {
        loop {
            if self.limit > 0 && self.emitted >= self.limit {
                return Ok(None);
            }
            if self.buffer_index < self.buffer.len() {
                let item = self.buffer[self.buffer_index].clone();
                self.buffer_index += 1;
                self.emitted += 1;
                return Ok(Some((item, self.meta.clone())));
            }
            if self.done {
                return Ok(None);
            }
            self.fetch()?;
        }
    }

    fn fetch(&mut self) -> Result<(), TransportError> {
        let mut opts = self.opts.clone();
        let variables = opts.entry("variables").or_insert_with(|| json!({}));
        let variables = variables
            .as_object_mut()
            .ok_or_else(|| validation("graphql.variables must be an object"))?;
        if self.kind == "cursor" {
            set_path(
                variables,
                &string_field(&self.pagination, "cursor_variable", "after"),
                self.cursor.clone(),
            );
            set_path(
                variables,
                &string_field(&self.pagination, "page_size_variable", "first"),
                json!(self.per_page),
            );
        } else {
            set_path(
                variables,
                &string_field(&self.pagination, "offset_variable", "offset"),
                json!(self.position),
            );
            set_path(
                variables,
                &string_field(&self.pagination, "limit_variable", "limit"),
                json!(self.per_page),
            );
        }
        let envelope = graphql_envelope(&self.base_url, &self.document, &opts)?;
        let data = envelope.get("data").unwrap_or(&JsonValue::Null);
        if self.kind == "cursor" {
            let connection_path = string_field(&self.pagination, "connection_path", "");
            let connection = extract_path(data, &connection_path)
                .ok_or_else(|| validation("connection_path not found"))?;
            let edges_path = string_field(&self.pagination, "edges_path", "edges");
            let node_path = string_field(&self.pagination, "node_path", "node");
            let edges = extract_path(connection, &edges_path)
                .and_then(JsonValue::as_array)
                .ok_or_else(|| validation("edges_path did not resolve to array"))?;
            self.buffer = edges
                .iter()
                .filter_map(|edge| extract_path(edge, &node_path).cloned())
                .collect();
            let page_info_path = string_field(&self.pagination, "page_info_path", "pageInfo");
            let page_info = extract_path(connection, &page_info_path).unwrap_or(&JsonValue::Null);
            let end_cursor_path = string_field(&self.pagination, "end_cursor_path", "endCursor");
            let has_next_path = string_field(&self.pagination, "has_next_page_path", "hasNextPage");
            self.cursor = extract_path(page_info, &end_cursor_path)
                .cloned()
                .unwrap_or(JsonValue::Null);
            let has_next = extract_path(page_info, &has_next_path)
                .and_then(JsonValue::as_bool)
                .unwrap_or(false);
            self.meta = json!({"kind":"cursor","page":self.page,"cursor":self.cursor});
            self.page += 1;
            self.done = !has_next || self.buffer.is_empty();
        } else {
            let items_path = string_field(&self.pagination, "items_path", "");
            self.buffer = extract_path(data, &items_path)
                .and_then(JsonValue::as_array)
                .ok_or_else(|| validation("items_path did not resolve to array"))?
                .clone();
            let page_start = self.position;
            self.position += self.buffer.len() as i64;
            let total_path = string_field(&self.pagination, "total_path", "");
            let total = extract_path(data, &total_path).and_then(JsonValue::as_i64);
            self.meta =
                json!({"kind":"offset","offset":page_start,"per_page":self.per_page,"total":total});
            self.done = self.buffer.len() < self.per_page
                || total.is_some_and(|total| self.position >= total);
        }
        self.buffer_index = 0;
        Ok(())
    }
}

fn set_path(root: &mut Map<String, JsonValue>, path: &str, value: JsonValue) {
    let mut parts = path.split('.').filter(|part| !part.is_empty()).peekable();
    let mut current = root;
    while let Some(part) = parts.next() {
        if parts.peek().is_none() {
            current.insert(part.to_owned(), value);
            return;
        }
        current = current
            .entry(part)
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .expect("variable path object");
    }
}

fn graphql_envelope(
    base_url: &str,
    document: &str,
    source_opts: &Map<String, JsonValue>,
) -> Result<JsonValue, TransportError> {
    let mut opts = source_opts.clone();
    let path = opts
        .remove("path")
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| "/graphql".to_owned());
    let variables = opts.remove("variables").unwrap_or_else(|| json!({}));
    let operation_name = opts.remove("operation_name").unwrap_or(JsonValue::Null);
    opts.insert(
        "body".to_owned(),
        json!({"query":document,"variables":variables,"operationName":operation_name}),
    );
    let envelope = request("POST", base_url, &path, &opts)?;
    if envelope
        .get("errors")
        .is_some_and(|errors| !errors.as_array().is_none_or(Vec::is_empty))
    {
        return Err(TransportError {
            code: "GRAPHQL_ERROR".into(),
            message: format!(
                "GraphQL response contained errors: {}; partial data: {}",
                envelope.get("errors").unwrap_or(&JsonValue::Null),
                envelope.get("data").unwrap_or(&JsonValue::Null)
            ),
            recoverable: true,
        });
    }
    Ok(envelope)
}

fn extract_path<'a>(value: &'a JsonValue, path: &str) -> Option<&'a JsonValue> {
    if path.is_empty() {
        return Some(value);
    }
    path.split('.')
        .try_fold(value, |current, part| current.get(part))
}

fn string_field(map: &Map<String, JsonValue>, key: &str, default: &str) -> String {
    map.get(key)
        .and_then(JsonValue::as_str)
        .unwrap_or(default)
        .to_owned()
}

fn int_field(map: &Map<String, JsonValue>, key: &str, default: i64) -> i64 {
    map.get(key).and_then(JsonValue::as_i64).unwrap_or(default)
}

fn request(
    method: &str,
    base_url: &str,
    path: &str,
    opts: &Map<String, JsonValue>,
) -> Result<JsonValue, TransportError> {
    request_cancellable(method, base_url, path, opts, None)
}

fn request_cancellable(
    method: &str,
    base_url: &str,
    path: &str,
    opts: &Map<String, JsonValue>,
    cancellation: Option<&std::sync::atomic::AtomicBool>,
) -> Result<JsonValue, TransportError> {
    if cancellation.is_some_and(|cancelled| cancelled.load(std::sync::atomic::Ordering::Acquire)) {
        return Err(TransportError {
            code: "CANCELLED".into(),
            message: "HTTP task cancelled".into(),
            recoverable: false,
        });
    }
    let method = Method::from_bytes(method.as_bytes()).map_err(validation)?;
    let mut url = compose_url(base_url, path)?;
    append_query(&mut url, opts.get("query"));
    let requested_timeout = opts
        .get("timeout")
        .and_then(JsonValue::as_f64)
        .filter(|timeout| timeout.is_finite() && *timeout > 0.0)
        .unwrap_or(60.0);
    let requested_timeout = Duration::from_secs_f64(requested_timeout);
    let client = client()?;
    let mut rate_retries = 0;
    let mut auth_retries = 0;
    let (status, headers, body) = loop {
        if cancellation
            .is_some_and(|cancelled| cancelled.load(std::sync::atomic::Ordering::Acquire))
        {
            return Err(TransportError {
                code: "CANCELLED".into(),
                message: "HTTP task cancelled".into(),
                recoverable: false,
            });
        }
        let timeout = crate::deadline::effective(requested_timeout)
            .ok_or_else(|| timeout_error("execution deadline exceeded"))?;
        let mut builder = client
            .request(method.clone(), url.clone())
            .timeout(timeout)
            .header("Accept", "application/json");
        builder = apply_headers(builder, opts.get("headers"))?;
        if let Some(auth) = opts.get("auth") {
            builder = apply_auth(builder, auth)?;
        }
        if let Some(body) = opts.get("body") {
            builder = builder.json(body);
        }
        let response = builder.send().map_err(reqwest_error)?;
        let status = response.status();
        if status.as_u16() == 401
            && auth_retries == 0
            && opts
                .get("auth")
                .is_some_and(crate::secrets::invalidate_command_bearer)
        {
            auth_retries += 1;
            continue;
        }
        if status.as_u16() == 429 && rate_retries == 0 {
            let wait = response
                .headers()
                .get("retry-after")
                .and_then(|value| value.to_str().ok())
                .and_then(parse_retry_after)
                .unwrap_or(Duration::ZERO);
            if wait <= Duration::from_secs(30) {
                let effective_wait = crate::deadline::effective(wait)
                    .ok_or_else(|| timeout_error("execution deadline exceeded during retry"))?;
                if effective_wait < wait {
                    return Err(timeout_error(
                        "execution deadline would expire before HTTP retry",
                    ));
                }
                rate_retries += 1;
                let started = std::time::Instant::now();
                while started.elapsed() < wait {
                    if cancellation.is_some_and(|cancelled| {
                        cancelled.load(std::sync::atomic::Ordering::Acquire)
                    }) {
                        return Err(TransportError {
                            code: "CANCELLED".into(),
                            message: "HTTP task cancelled".into(),
                            recoverable: false,
                        });
                    }
                    thread::sleep(Duration::from_millis(20));
                }
                continue;
            }
        }
        let headers = response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|value| (name.to_string(), JsonValue::String(value.to_owned())))
            })
            .collect::<Map<_, _>>();
        let max_bytes = opts
            .get("max_response_bytes")
            .and_then(JsonValue::as_u64)
            .and_then(|value| usize::try_from(value).ok())
            .unwrap_or(DEFAULT_JSON_RESPONSE_BYTES)
            .min(MAX_JSON_RESPONSE_BYTES);
        let mut bytes = Vec::new();
        response
            .take(max_bytes.saturating_add(1) as u64)
            .read_to_end(&mut bytes)
            .map_err(http_error)?;
        if bytes.len() > max_bytes {
            return Err(TransportError {
                code: "RESULT_TOO_LARGE".into(),
                message: format!("HTTP JSON response exceeds max_response_bytes={max_bytes}"),
                recoverable: false,
            });
        }
        let body = String::from_utf8(bytes).map_err(|_| TransportError {
            code: "HTTP_ERROR".into(),
            message: "HTTP JSON response is not valid UTF-8".into(),
            recoverable: false,
        })?;
        break (status, headers, body);
    };
    if !status.is_success() {
        return Err(TransportError {
            code: "HTTP_ERROR".to_owned(),
            message: format!("HTTP {}: {}", status.as_u16(), truncate(&body, 4096)),
            recoverable: status.is_server_error(),
        });
    }
    if method == Method::HEAD || body.trim().is_empty() {
        return Ok(JsonValue::Null);
    }
    let decoded = serde_json::from_str(&body).map_err(|error| TransportError {
        code: "HTTP_ERROR".to_owned(),
        message: format!("failed to parse JSON response: {error}"),
        recoverable: true,
    })?;
    if opts.get("response_mode").and_then(JsonValue::as_str) == Some("http_envelope") {
        Ok(json!({"status":status.as_u16(),"headers":headers,"body":decoded}))
    } else {
        Ok(decoded)
    }
}

pub(crate) fn request_bytes(
    method: &str,
    base_url: &str,
    path: &str,
    opts: &Map<String, JsonValue>,
    max_bytes: usize,
) -> Result<Vec<u8>, TransportError> {
    let method = Method::from_bytes(method.as_bytes()).map_err(validation)?;
    let mut url = compose_url(base_url, path)?;
    append_query(&mut url, opts.get("query"));
    let requested_timeout = opts
        .get("timeout")
        .and_then(JsonValue::as_f64)
        .filter(|timeout| timeout.is_finite() && *timeout > 0.0)
        .unwrap_or(60.0);
    let requested_timeout = Duration::from_secs_f64(requested_timeout);
    let client = client()?;
    let mut auth_retries = 0;
    let response = loop {
        let timeout = crate::deadline::effective(requested_timeout)
            .ok_or_else(|| timeout_error("execution deadline exceeded"))?;
        let mut builder = client.request(method.clone(), url.clone()).timeout(timeout);
        builder = apply_headers(builder, opts.get("headers"))?;
        if let Some(auth) = opts.get("auth") {
            builder = apply_auth(builder, auth)?;
        }
        let response = builder.send().map_err(reqwest_error)?;
        if response.status().as_u16() == 401
            && auth_retries == 0
            && opts
                .get("auth")
                .is_some_and(crate::secrets::invalidate_command_bearer)
        {
            auth_retries += 1;
            continue;
        }
        break response;
    };
    let status = response.status();
    let read_limit = if status.is_success() {
        max_bytes.saturating_add(1)
    } else {
        4097
    };
    let mut body = Vec::new();
    response
        .take(read_limit as u64)
        .read_to_end(&mut body)
        .map_err(http_error)?;
    if !status.is_success() {
        return Err(TransportError {
            code: "HTTP_ERROR".to_owned(),
            message: format!(
                "HTTP {}: {}",
                status.as_u16(),
                truncate(&String::from_utf8_lossy(&body), 4096)
            ),
            recoverable: status.is_server_error(),
        });
    }
    if body.len() > max_bytes {
        return Err(TransportError {
            code: "RESULT_TOO_LARGE".to_owned(),
            message: format!("blob exceeds max_bytes={max_bytes}"),
            recoverable: false,
        });
    }
    Ok(body)
}

fn parse_retry_after(value: &str) -> Option<Duration> {
    if let Ok(number) = value.trim().parse::<u64>() {
        if number >= 1_000_000_000_000 {
            let target = UNIX_EPOCH + Duration::from_millis(number);
            return Some(
                target
                    .duration_since(SystemTime::now())
                    .unwrap_or(Duration::ZERO),
            );
        }
        if number >= 1_000_000_000 {
            let target = UNIX_EPOCH + Duration::from_secs(number);
            return Some(
                target
                    .duration_since(SystemTime::now())
                    .unwrap_or(Duration::ZERO),
            );
        }
        return Some(Duration::from_secs(number));
    }
    None
}

fn compose_url(base_url: &str, path: &str) -> Result<Url, TransportError> {
    let mut url = Url::parse(base_url).map_err(validation)?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(TransportError {
            code: "VALIDATION_FAILED".into(),
            message: "base_url must be HTTP(S) and include a host".into(),
            recoverable: false,
        });
    }
    if Url::parse(path).is_ok() {
        return Err(TransportError {
            code: "VALIDATION_FAILED".into(),
            message: "path must be relative".into(),
            recoverable: false,
        });
    }
    let joined = format!(
        "{}{}",
        url.path().trim_end_matches('/'),
        if path.starts_with('/') {
            path.to_owned()
        } else {
            format!("/{path}")
        }
    );
    url.set_path(&joined);
    Ok(url)
}

fn append_query(url: &mut Url, value: Option<&JsonValue>) {
    let Some(JsonValue::Object(query)) = value else {
        return;
    };
    let mut pairs = url.query_pairs_mut();
    for (name, value) in query {
        match value {
            JsonValue::Array(values) => {
                for value in values {
                    pairs.append_pair(name, &scalar(value));
                }
            }
            value => {
                pairs.append_pair(name, &scalar(value));
            }
        }
    }
}

fn scalar(value: &JsonValue) -> String {
    value
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| value.to_string())
}

fn apply_auth(
    builder: reqwest::blocking::RequestBuilder,
    auth: &JsonValue,
) -> Result<reqwest::blocking::RequestBuilder, TransportError> {
    let kind = auth
        .get("kind")
        .and_then(JsonValue::as_str)
        .unwrap_or_default();
    match kind {
        "bearer" => Ok(builder.bearer_auth(resolve_secret(&auth["token"])?)),
        "basic" => {
            let username = resolve_secret(&auth["username"])?;
            let password = resolve_secret(&auth["password"])?;
            Ok(builder.header(
                "Authorization",
                format!(
                    "Basic {}",
                    STANDARD.encode(format!("{username}:{password}"))
                ),
            ))
        }
        _ => Err(TransportError {
            code: "VALIDATION_FAILED".into(),
            message: "unsupported auth reference".into(),
            recoverable: false,
        }),
    }
}

fn apply_headers(
    mut builder: reqwest::blocking::RequestBuilder,
    headers: Option<&JsonValue>,
) -> Result<reqwest::blocking::RequestBuilder, TransportError> {
    match headers {
        None => {}
        Some(JsonValue::Object(headers)) => {
            for (name, value) in headers {
                let value = value
                    .as_str()
                    .ok_or_else(|| validation(format!("header {name} must be a string")))?;
                builder = builder.header(name, value);
            }
        }
        Some(JsonValue::Array(headers)) => {
            for (index, entry) in headers.iter().enumerate() {
                let name = entry
                    .get("name")
                    .and_then(JsonValue::as_str)
                    .filter(|name| !name.trim().is_empty())
                    .ok_or_else(|| {
                        validation(format!("headers entry {} requires name", index + 1))
                    })?;
                let value = entry
                    .get("value")
                    .and_then(JsonValue::as_str)
                    .ok_or_else(|| {
                        validation(format!("headers entry {} requires value", index + 1))
                    })?;
                builder = builder.header(name, value);
            }
        }
        Some(_) => return Err(validation("headers must be a table or ordered list")),
    }
    Ok(builder)
}

fn resolve_secret(value: &JsonValue) -> Result<String, TransportError> {
    crate::secrets::resolve(value).map_err(|error| TransportError {
        code: error.code,
        message: error.message,
        recoverable: error.recoverable,
    })
}

fn validation(error: impl std::fmt::Display) -> TransportError {
    TransportError {
        code: "VALIDATION_FAILED".into(),
        message: error.to_string(),
        recoverable: false,
    }
}
fn http_error(error: impl std::fmt::Display) -> TransportError {
    TransportError {
        code: "HTTP_ERROR".into(),
        message: error.to_string(),
        recoverable: true,
    }
}
fn reqwest_error(error: reqwest::Error) -> TransportError {
    if error.is_timeout() {
        timeout_error(error.to_string())
    } else {
        http_error(error)
    }
}
fn timeout_error(message: impl Into<String>) -> TransportError {
    TransportError {
        code: "TIMEOUT".into(),
        message: message.into(),
        recoverable: true,
    }
}
fn truncate(value: &str, length: usize) -> &str {
    if value.len() <= length {
        return value;
    }
    let boundary = value
        .char_indices()
        .map(|(index, _)| index)
        .take_while(|index| *index <= length)
        .last()
        .unwrap_or(0);
    &value[..boundary]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_composition_preserves_base_prefix() {
        let url = compose_url("https://example.test/wiki", "/rest/api").unwrap();
        assert_eq!(url.as_str(), "https://example.test/wiki/rest/api");
        assert!(compose_url("file:///tmp", "/bad").is_err());
        assert!(compose_url("https://example.test", "https://evil.test").is_err());
    }

    #[test]
    fn retry_after_supports_seconds_and_unix_timestamps() {
        assert_eq!(parse_retry_after("2"), Some(Duration::from_secs(2)));
        let past = parse_retry_after("1000000000").unwrap();
        assert_eq!(past, Duration::ZERO);
        assert!(parse_retry_after("not-a-time").is_none());
    }

    #[test]
    fn token_pagination_configuration_is_accepted() {
        let state = HttpListState::new(
            "POST".into(),
            "https://example.test".into(),
            "/items".into(),
            serde_json::from_value(json!({
                "body": {"filter":"open"},
                "pagination": {
                    "kind":"token",
                    "items_path":"items",
                    "token_param":"nextToken",
                    "next_token_path":"nextToken",
                    "missing_items_as_empty":true
                }
            }))
            .unwrap(),
        )
        .unwrap();
        assert_eq!(state.kind, "token");
        assert_eq!(state.token_parameter, "nextToken");
        assert!(state.missing_items_as_empty);
    }

    #[test]
    fn cursor_links_preserve_origin_and_extract_query() {
        let mut opts = Map::new();
        let path = apply_cursor_link(
            "https://example.test/wiki",
            "/wiki/api/v2/pages?cursor=next&tag=a&tag=b",
            &mut opts,
        )
        .unwrap();
        assert_eq!(path, "/api/v2/pages");
        assert_eq!(opts["query"]["cursor"], "next");
        assert_eq!(opts["query"]["tag"], json!(["a", "b"]));
        assert!(
            apply_cursor_link(
                "https://example.test/wiki",
                "https://evil.test/steal",
                &mut opts
            )
            .is_err()
        );
    }
}
