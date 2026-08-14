# Architecture

This document is the living source of truth for the **implemented core architecture** of this MCP server. It records current behavior, ownership boundaries, known limitations, and proposed architectural improvements.

Service-pack layout and authoring conventions belong in [services/SERVICE-DESIGN.mkd](services/SERVICE-DESIGN.mkd).

> The project is under active development. Backward compatibility is not currently a constraint.
>
> Sections 1–14 describe the current implementation. Section 15 is a proposed improvement backlog and must not be read as implemented behavior.

## 1. Purpose and trust model

The server executes Lua locally and exposes the runtime through MCP over stdio. The core is responsible for:

- loading filesystem-based Lua service packs;
- maintaining a Lua runtime per MCP session;
- exposing schema-backed Lua APIs and capability discovery;
- distinguishing read-only and guarded MCP calls;
- providing CLI, HTTP, GraphQL, task, namespaced KV, snippets, VFS, blob, secret, and ingest facilities; and
- capturing execution output, metrics, and optional execution logging.

Service packs are not compiled into the binary. The repository ships service packs, but the runtime still loads them as external files from the configured services directory.

### 1.1 Current trust boundaries

The current implementation has two materially different code classes:

| Code | Current trust assumption |
| --- | --- |
| Rust core | Trusted. Owns process, transport, persistence, and Lua embedding. |
| Embedded core Lua | Trusted. Loaded from the binary with `include_str!`. |
| Filesystem service packs | **Fully trusted host code.** They execute in the trusted Lua global environment. The VM is created with mlua's safe standard libraries, so native/C module loading is unavailable. |
| Persisted Lua snippets | Trusted after human-approved installation. They compile and execute in the trusted Lua global environment. |
| MCP session scripts | Untrusted. Each execution uses a separate allowlisted Lua `_ENV` containing pure-Lua helpers and cloned public API tables only; it has no `sys`, `io`, `os`, `debug`, `package`, `require`, `dofile`, `loadfile`, or `load`. |
| CLI user scripts | Local trusted code. Direct raw access remains enabled. |

This distinction is important: service packs can use host-facing Lua facilities independently of `sys.*`, so the CLI allowlist and VFS do not sandbox a malicious service pack.

## 2. Process topology and thread model

```text
MCP client                                  Local shell
    |                                           |
    | JSON-RPC over stdio                       | CLI/subcommand
    v                                           v
rmcp server + command routing (`main.rs`, `mcp.rs`)
                         |
                         v
        McpServer -> session map -> Session -> LuaRuntime
                                      |
                 +--------------------+--------------------+
                 |                    |                    |
          embedded core Lua     service-pack Lua     persisted snippets
                 |                    |                    |
                 +--------------------+--------------------+
                                      |
                            schema-backed functions
                                      |
                              guarded `sys.*`
                                      |
       +---------------+--------------+-------------+---------------+
       |               |                            |               |
 CLI subprocesses  blocking HTTP/GraphQL       store/VFS/blob   ingest IPC
       |               |                            |               |
 external tools    external/local APIs          local disk/RAM   Unix socket
```

The executable uses a Tokio multi-thread runtime for the MCP server. The current MCP tool handlers call synchronous Lua, process, and blocking HTTP code directly from async handlers; they do not use `spawn_blocking` or a dedicated worker pool.

Additional native threads are created for:

- the Unix ingest listener and each accepted ingest connection;
- each background task;
- stdout and stderr readers for each captured subprocess.

A `LuaRuntime` uses `mlua` with the `send` feature, but a session serializes access to its VM with a `parking_lot::Mutex`.

## 3. Process interfaces and configuration

### 3.1 Commands

| Command | Current behavior |
| --- | --- |
| default / `run [file]` | Execute stdin or a file in a new runtime, in guarded mode. There is no interactive REPL. |
| `mcp` | Serve MCP over stdin/stdout and, on Unix, start the local ingest socket. |
| `validate` | Construct a runtime to catch load failures, then count files named `init.lua`. It does **not** force capability/schema validation. |
| `test` | Find Lua files below any `tests` path and execute each in a new read-only test runtime. |
| `ingest` | Send UTF-8 stdin to an already-created MCP session through its Unix socket. |
| `list-sys` | Construct a runtime and enumerate registered `sys.*` functions. |
| `stats` | Combine available schema paths with metrics found in the durable store. |

CLI execution permits direct `sys.*` calls and uses guarded mode. Service tests permit direct raw calls, retain the full standard library, and initially use read-only mode.

### 3.2 Path resolution

The service directory is resolved in this order:

1. `--svc-dir`
2. `MUNRAY_MCP_SVC_DIR`
3. `$MUNRAY_MCP_HOME/services`
4. `$HOME/.local/share/<package-name>/services`

The store path is resolved from `--store-path`, `MUNRAY_MCP_STORE_PATH`, or `<data-home>/store.db`. Relative store paths are made absolute against the process working directory.

Telemetry is disabled unless `--logs-dir` or `MUNRAY_MCP_LOGS_DIR` is supplied. The package/binary name and default data-directory leaf derive from Cargo package metadata; the canonical product name is in `Cargo.toml`.

`main.rs` resolves a store path before routing any command. Consequently, even commands that do not logically need persistence require either a store override or a usable `HOME`.

## 4. Source map

| Area | Primary files | Responsibilities |
| --- | --- | --- |
| CLI/configuration | `src/main.rs` | Argument parsing, path resolution, command routing, service test runner. |
| MCP server | `src/mcp.rs` | Tools, elicitation, sessions, ordering, timeout selection, response encoding. |
| Lua runtime | `src/runtime.rs` | VM construction, raw registration, preload, execution, conversion, restrictions. |
| Durable storage | `src/storage.rs` | SQLite lifecycle, KV expiry, metrics, snippets, schema initialization, and Lua storage bridges. |
| Service loading | `src/services.rs` | Deterministic source/example discovery and execution. |
| Core Lua bootstrap | `src/preload/*.lua` | Helpers, capabilities, KV/snippet schemas, tasks, VFS, ingest, error translation, and tests. |
| HTTP/GraphQL | `src/http.rs` | Requests, auth application, retries, pagination, async request starters. |
| Process execution | `src/process.rs` | Child lifecycle, timeout/cancellation polling, bounded output capture. |
| Tasks | `src/tasks.rs` | Per-runtime task registry, worker threads, status/result/wait/cancel. |
| Secrets/auth | `src/secrets.rs` | Environment and command secret references, resolution and TTL cache. |
| VFS/blob/ingest | `src/vfs.rs`, `src/blob.rs`, `src/ingest.rs` | Runtime-local files, binary handles, uploaded text. |
| Ingest IPC | `src/ipc.rs` | Unix socket endpoint and wire protocol. |
| Execution logging/stats | `src/logging.rs`, `src/stats.rs` | Execution JSONL and function-usage reports. |
| Deadline propagation | `src/deadline.rs` | Thread-local deadline used by selected synchronous nested operations. |

## 5. State ownership and lifetimes

| Scope | State | Lifetime and sharing |
| --- | --- | --- |
| Process-global | SQLite connection registry | Maps absolute database paths to one mutex-protected reusable SQLite connection. All runtimes in one process using the same path share it. |
| Process-global | command-secret registry | Maps generated IDs to command-secret definitions. Entries are not currently removed. |
| Process-global | pending MCP arrivals | Keyed by `session_id`; used by same-session ordering. |
| `McpServer` | session map, service/store paths, TTL, optional logger | Shared across cloned server handlers. |
| `Session` | one mutex-protected `LuaRuntime`, queue state, last-used time | Retained in the server map until lazily evicted. |
| `LuaRuntime` | Lua VM, output, mode, immutable function registry, Rust raw-authorization state, optional session environment, CLI allowlist, VFS, blobs, ingest | One per CLI invocation, service test, or MCP session. |
| Runtime closures | task manager | Shared by raw task/transport functions in one runtime. |
| Runtime | VFS `TempDir` and exposure bundles | Removed when their final owning references are dropped. |
| Runtime | blob and ingest maps | Session/runtime-local and memory-resident. |

The durable store is shared between MCP sessions. Trusted Lua globals, function registry, tasks, VFS files, blobs, ingest tokens, and the cloned MCP session environment are runtime-local.

## 6. Exact runtime construction sequence

`LuaRuntime::build` currently performs these steps:

1. Create a safe Lua 5.4 VM with `Lua::new_with(StdLib::ALL_SAFE, ...)`; trusted service tests use the full VM because their fixtures require it.
2. Create runtime-local VFS/blob/ingest/output state, Rust raw-authorization state, and an immutable function registry.
3. Open or create the shared store map and register Rust raw facilities, including internal storage and public namespaced KV operations.
4. Wrap every raw Rust function with a Rust authorization guard. Bootstrap is initially authorized.
5. Execute the embedded modular trusted preload code, then load trusted service packs and restored snippets.
6. Install Rust-created schema wrappers, each capturing immutable operation policy and original Lua function. Their RAII raw scope authorizes nested raw calls and iterator steps.
7. Disable bootstrap authorization and retain direct raw access only for local CLI/test runtimes.
8. For MCP runtimes, build a separate session `_ENV` containing pure Lua facilities and cloned public API tables. Raw/internal globals and unsafe standard libraries are omitted.

The modular preload files are the sole Lua bootstrap implementation. Their explicit load order in `runtime.rs` is the dependency order between core Lua namespaces.

### 6.1 Direct-raw and standard-library modes

| Runtime constructor/use | Direct `sys.*` | User-visible standard library |
| --- | --- | --- |
| MCP session (`new_mcp`) | Guarded | Partially restricted |
| CLI (`new_persistent`) | Allowed | Partially restricted |
| General library runtime (`new`) | Allowed | Partially restricted |
| Service test (`new_with_options(..., true)`) | Allowed | Full |

Service source and persisted snippets load before restrictions are applied. Wrapped external functions temporarily restore the full `io`, `os`, `package`, and `require` values captured at bootstrap.

## 7. Service loading and capability discovery

### 7.1 Service source and examples

`services::load` scans immediate child directories of the configured services directory, sorted by name. It processes one complete service at a time.

For each service:

- `<service>/src` is walked recursively with symlinks followed;
- every Lua file whose filename is `init.lua` sorts before non-`init.lua` files, followed by path order;
- files execute one-by-one with their filesystem path as the chunk name;
- `<service>/examples/**/*.lua` files are read as text, not executed; and
- relative example path components have `_` converted to `.`, then are prefixed with the service name unless the file is the service-level example.

Walk errors are currently discarded through `filter_map(Result::ok)`. A missing service directory is accepted and leaves only core APIs available.

Service packs may declare `__intro`, but the MCP initialization response currently does not discover or include it. Initialization instructions are a fixed string in `McpServer::get_info`.

### 7.2 Schemas and capabilities

A public namespace is a Lua table with `__schema`. The modular capabilities implementation:

- discovers schema roots by walking selected tables in `_G`;
- validates required namespace/function fields on first discovery;
- caches schemas, functions, types, examples, and warnings;
- exposes `capabilities.ai_context`, `schema`, `schemas`, `examples`, and `invalidate`; and
- optionally warns about missing examples when `MUNRAY_MCP_WARN_MISSING_EXAMPLES=1` was visible during bootstrap.

Capability discovery is lazy. `validate` constructs a runtime but does not call capability discovery, so malformed schema metadata can survive `validate` until a capability function is used.

Dynamic snippet installation and deletion invalidate the capability cache, so the next `capabilities.ai_context()`, `schema`, `schemas`, or `examples` call discovers the current snippet functions.

## 8. MCP request lifecycle

### 8.1 Initialization and tools

The server uses `rmcp` with stdio transport and advertises tool support. Server name/version come from Cargo compile-time metadata.

It exposes two tools:

| Tool | Execution mode |
| --- | --- |
| `runLuaScript` | `ReadOnly` |
| `runGuardedLuaScript` | `Guarded` |

Both accept:

- required non-empty `code`;
- optional `session_id`; and
- optional `timeout_ms`, clamped to 100–600,000 ms with a 60,000 ms default.

### 8.2 Session creation and reuse

On the first call for a session ID, the server constructs a complete runtime and loads all service packs while holding the global session-map lock. A missing `session_id` causes the server to generate a UUID, retain that session, and return the UUID in the tool payload; the caller can reuse the returned ID later.

The runtime stores the MCP process ID in `__runtime.server_id`, which `capabilities.ai_context()` exposes for ingest workflows.

Sessions expire after 30 minutes of inactivity, but cleanup is **lazy**: expiration is checked only while admitting an execution. There is no periodic cleanup loop and no explicit session-close API. An in-flight `Arc` reference prevents eviction.

### 8.3 Same-session ordering

Independent sessions can execute concurrently. Same-session calls are intended to execute in FIFO order, but the current mechanism is not a dedicated queue:

1. Numeric non-negative JSON-RPC request IDs are used as arrival numbers.
2. Other IDs receive a process-global atomic number.
3. Arrival numbers are stored in a process-global `BTreeSet` per session.
4. A request sleeps for 5 ms, then waits until its number is the smallest pending value.

This orders increasing numeric request IDs, which is not necessarily the same as wire-arrival order. Runtime-creation errors can also leave pending arrival state behind because cleanup is not RAII-based.

### 8.4 Guarded elicitation

If the client advertises form elicitation, the guarded tool requests an `Approve`/`Reject` decision before execution. Decline, cancel, or any accepted value other than `Approve` returns a `REJECTED_BY_GUARD` payload and does not execute code.

Current fallback is permissive:

- if the client does not advertise form elicitation, execution proceeds; and
- if an advertised elicitation request fails, execution also proceeds.

### 8.5 Response shape

Normal tool execution returns a text content item containing pretty-printed JSON:

```json
{
  "session_id": "...",
  "output": "captured print output",
  "result": null,
  "error": null
}
```

An uncaught execution failure is generally encoded as a string in `error` while the tool call itself remains successful at the MCP protocol layer. Empty code and some pre-execution failures return an MCP tool error instead.

## 9. Lua execution, deadlines, and value conversion

### 9.1 Execution

Before each execution the runtime:

1. sets the current `ExecutionMode`;
2. clears the shared print buffer;
3. installs an instruction hook when a timeout was supplied;
4. enters a thread-local deadline scope; and
5. evaluates the code as a Lua chunk with `mlua::Chunk::eval`.

The hook checks every 10,000 Lua instructions. MCP supplies a timeout; the local CLI currently calls `execute` without an overall Lua timeout, so pure Lua code can run indefinitely there.

The thread-local deadline constrains selected synchronous nested operations, including CLI capture, HTTP, blob capture, and command secrets. It does not automatically constrain all Rust callbacks. For example, `async_task.wait` blocks inside Rust using its own timeout, VFS ZIP subprocesses have no deadline, and background tasks do not inherit the caller thread's deadline.

### 9.2 Output and return conversion

`print` joins arguments with tabs and appends a newline. Output is retained on MCP execution failure, but CLI error handling currently returns before printing captured output or writing a failed-execution log entry.

Return conversion rules are:

- zero returns or only trailing nil values -> JSON `null`;
- one value -> scalar/object/array;
- multiple values -> JSON array;
- empty unmarked Lua table -> JSON object;
- a table with contiguous integer keys `1..N` -> JSON array;
- a table marked with `__mcp_json_array` -> JSON array, honoring its optional `n`; and
- other tables -> JSON objects with scalar keys converted to strings.

`json.decode` marks JSON arrays so empty arrays and embedded nulls can round-trip. If a top-level return cannot be converted, execution currently falls back to its Lua string representation; an unsupported value nested in a table can cause the whole table to be stringified.

## 10. Policy enforcement and Lua restrictions

### 10.1 Schema mutation gate

After trusted loading, Rust walks schema namespace tables and records immutable operation metadata in a per-runtime registry. It replaces each matching public function with a Rust closure that captures the original Lua function, mutation policy, return contract, and operation path. It rejects captured guarded functions in read-only mode and wraps iterators so each step has the same authorization.

Mutation policy is never read from mutable Lua descriptors at call time. Session code receives cloned public tables, so descriptor/function reassignment cannot alter trusted globals or registry entries. Human-approved `snippets.save` and `snippets.delete` update the Rust registry and refresh those public clones immediately.

### 10.2 Raw guard

Every raw Rust callback is replaced with a Rust guard closure. The guard consults Rust-owned bootstrap/direct-access/depth state and returns `(nil, RAW_OUTSIDE_SCHEMA)` unless direct raw access is enabled or an RAII scope from a registered public wrapper is active. Iterator steps enter a separate Rust scope. Session environments do not expose `sys` at all.

There is no Lua wrapper installer or Lua raw-context counter.

### 10.3 Standard-library restrictions

Non-test VMs use mlua's safe standard-library constructor, which prevents native/C module loading. MCP session chunks execute with a separate allowlisted `_ENV`; it contains pure Lua primitives and cloned public API tables, but not host-facing standard libraries, raw globals, package loading, or `load`/file loaders. Trusted core/service/snippet code remains in the trusted global environment.

This is a Lua-language boundary, not OS process isolation. Trusted service packs and approved snippets intentionally retain the safe VM's host-facing Lua facilities; architectural security must not treat them as contained to `sys.*` or the VFS.

### 10.4 CLI allowlist

The raw CLI and command-secret implementations require exact command-name membership in the aggregated allowlist. The default list is empty. This protects accidental raw CLI use, but it is not a command sandbox:

- allowing a shell permits arbitrary shell behavior;
- `cwd` may refer to arbitrary host paths;
- child processes inherit the server environment; and
- trusted service code can use restored standard-library facilities outside the raw CLI path.

## 11. Core Lua API and raw facilities

### 11.1 Raw surface

| Namespace | Implemented operations |
| --- | --- |
| `sys` | `exec_mode` |
| `sys.auth` | `basic`, `bearer` |
| `sys.blob` | `from_cli`, `from_http`, `len` |
| `sys.cli` | `text`, `json`, `start_text`, `start_json` |
| `sys.graphql` | `request`, `list`, `start_request` |
| `sys.http` | `request`, `list`, `start_request` |
| `sys.ingest` | `get` |
| `sys.secrets` | `env`, `command` |
| `sys.kv` | `put`, `get`, `delete`, `keys`, `len`, `clear` |
| `sys.snippets` | `save`, `get`, `list`, `delete` |
| `sys.task` | `status`, `result`, `wait`, `cancel` |
| `sys.test` | `set_mode`, `start_task` |
| `sys.url` | query/path escape and unescape |
| `sys.vfs` | `mkdirp`, text/blob write, text read, `stat`, `list`, `to_text`, `expose` |

Public core namespaces include `json`, `yaml`, `helpers`, `store`, `async_task`, `vfs`, `ingest`, and `capabilities`. `errutil` is intentionally internal and has no schema.

### 11.2 CLI and process capture

Synchronous CLI calls poll the child every 10 ms, drain stdout/stderr concurrently, and kill the immediate child on timeout. Stdout is capped at 200 MiB by default and stderr retention at 1 MiB; readers continue draining after the retained cap to avoid pipe deadlock. Child process groups are not managed, so descendants can outlive a killed parent.

Text mode decodes stdout lossily as UTF-8. JSON mode parses stdout as JSON. Nonzero exits return `CLI_ERROR`; timeout and output overflow use separate error codes.

### 11.3 HTTP and GraphQL

The transport uses a new blocking `reqwest::Client` per request. HTTP options support query values, JSON body, map or ordered-list headers, auth references, and timeout.

HTTP behavior includes:

- only HTTP(S) base URLs with a host;
- relative request paths appended to any base path prefix;
- JSON decoding for normal requests;
- one command-bearer refresh/retry after HTTP 401;
- one HTTP 429 retry when `Retry-After` is numeric and no more than 30 seconds; and
- a 4 KiB error-body message, although normal JSON responses are read without an explicit body-size cap.

HTTP pagination is lazy and supports `page`, `offset`, opaque `token`, and same-origin cursor-link modes. Cursor links must preserve scheme, host, port, and configured base-path prefix.

GraphQL uses HTTP POST and supports data or envelope response mode plus cursor/offset pagination. The current envelope is the decoded GraphQL response body; it does not add HTTP status/header metadata. A non-empty GraphQL `errors` array becomes a generic `GRAPHQL_ERROR`; error details and partial data are not preserved.

### 11.4 Background tasks

Each runtime has one task registry. A task has a UUID, timestamps, cancellation flag, and one of four states: `running`, `completed`, `failed`, or `cancelled`.

Current behavior:

- at most 10 running tasks are admitted per runtime;
- each task starts an unbounded native thread;
- CLI task cancellation is observed by the process polling loop;
- HTTP/GraphQL task closures ignore their cancellation token, so cancellation changes visible state but does not abort the request;
- `async_task.wait` polls every 20 ms and defaults to 295 seconds;
- completed task records have no retention cleanup; and
- dropping/evicting a runtime does not explicitly cancel its running tasks.

There is no general 10 MiB result limit or five-minute cleanup in the Rust task manager, despite stale comments in `src/preload/task.lua` that describe such retention.

### 11.5 Secrets and auth

Secret and auth references are Lua tables, not opaque userdata. Environment references store an environment-variable name. Command references store an ID into a process-global Rust registry.

Command-secret rules:

- command must be on the runtime CLI allowlist;
- timeout defaults to 10 seconds and is limited to 30 seconds;
- successful stdout is trimmed, must be non-empty UTF-8, and is cached for `ttl_s` (default one hour); and
- a command-backed bearer cache is invalidated once after HTTP 401.

The process-global command registry has no cleanup. It retains definitions after their runtime expires, although a weak allowlist reference prevents successful resolution after runtime destruction.

### 11.6 VFS and blobs

Each runtime owns a temporary VFS root. VFS paths must be non-empty, relative, free of parent/root/prefix components, and limited to ASCII alphanumerics plus `.`, `_`, `/`, and `-`.

The VFS provides directory creation, text/blob writes, text reads, metadata, recursive/nonrecursive listing, ZIP extraction/previews, and exposure bundles. VFS writes are declared non-guarded by policy because they affect runtime-local scratch space; `vfs.expose` is guarded because it creates host-visible copies.

ZIP conversion shells out to `unzip` without the service CLI allowlist or execution deadline. It limits the number of files and preview bytes but not total extracted bytes, so archive expansion can consume substantial memory/disk. Exposure bundles remain alive until the runtime drops.

Blob bytes are held in an in-memory map and represented in Lua by userdata. The default per-capture limit is 200 MiB, but callers can request a different limit. There is no aggregate blob quota or eviction.

### 11.7 Ingest and local IPC

On Unix, `mcp` binds `<temp-dir>/<package-name>-ingest-<pid>.sock`, removes a pre-existing path with that name, and sets socket mode `0600`.

The protocol is:

1. one JSON header line containing operation, session ID, and byte count;
2. exactly that many payload bytes; and
3. one JSON response line.

Payloads are limited to 64 MiB and must be UTF-8. The target session must already exist. The text is written below that runtime's VFS and associated with a random `ing_<32 hex>` token. Tokens are session-local and repeatable until the runtime is dropped.

The listener uses detached native threads. Dropping its guard removes the socket path but does not provide a coordinated thread-shutdown protocol.

## 12. Persistence, snippets, metrics, and statistics

### 12.1 Store representation

The durable store is SQLite, implemented in `src/storage.rs`. It owns independent `kv_entries`, `metrics`, and `snippets` relations and creates them transactionally on open. Connections use WAL, normal synchronous durability, a 64 MiB page cache, in-memory temporary storage, and foreign-key enforcement. A process reuses one mutex-protected connection per absolute database path; SQLite coordinates writers in other processes.

Generic KV rows retain JSON text, content type, timestamps, and an optional expiry. Expired KV rows are hidden at `expires_at_s <= now` and lazily removed during get, keys, and count. There is no core cache API or cache relation: callers use a normal durable namespace and set expiry themselves. Metrics and snippets are core-owned relations and are not reachable through generic KV.

### 12.2 Persisted snippets

Complete snippet rows are restored during startup. The public `snippets.save` definition uses `namespace` and `name` (for example, `{namespace="math", name="fibonacci"}` installs `math.fibonacci`); the durable store uses an internal dotted identifier. Its `code` may be a function expression, a chunk that returns a function, or a named Lua function declaration. Function text is compiled in the global environment, namespaces are created dynamically, descriptors are attached, and security wrappers are reinstalled. Snippets default to `readonly = true` unless schema text says otherwise.

Installing/deleting a snippet changes only the current Lua runtime immediately. Deleting the final snippet from a snippet-created namespace prunes that empty namespace, so it is no longer discoverable. Other existing sessions share its durable records but do not install/remove the corresponding Lua function until they are recreated or explicitly updated themselves.

### 12.3 Function metrics and `stats`

Schema wrappers intend to increment:

- `fn.<path>.calls`;
- `fn.<path>.err`; and
- `fn.<path>.blocked`.

Metric increments use an atomic SQLite upsert. They are issued by the Rust schema wrapper, so both MCP and CLI calls record usage without routing through a guarded raw Lua function.

`stats` creates a runtime to discover currently available function paths, reads historical metric records from the store, and reports both available functions and metrics for functions that no longer exist.

## 13. Telemetry and errors

### 13.1 Execution logging

When enabled, execution logging appends JSON lines to `<logs-dir>/executions.jsonl`. Each entry includes timestamp, session, mode, full Lua code, output, result, error, and duration. Unix creation modes are `0700` for a newly-created directory and `0600` for the file.

Telemetry contains unredacted code and values and can therefore contain secrets. Logger behavior also differs by surface:

- CLI logger creation/write errors propagate, but only successful executions are logged;
- MCP logger creation failure silently disables logging; and
- MCP log-write failures are ignored.

The logger mutex is per `Logger` instance; it is not an inter-process file lock.

### 13.2 Error forms

Expected raw/public failures generally use `(nil, err)` with `code`, `message`, `recoverable`, and optional context/hints. `errutil` can translate and sanitize transport errors before they become public.

Iterator transport failures are thrown from the raw iterator. Helper consumers catch them and coerce them to a public `ITERATION_FAILED` shape.

Uncaught Lua/embedding errors are `anyhow` strings. MCP places the formatted string in the payload's `error` field; it does not currently preserve a uniform structured error object or consistently mark the MCP tool result as an error.

## 14. Current limits and verification

| Resource/behavior | Current value |
| --- | --- |
| MCP call timeout | 60 s default, clamped to 100 ms–10 min |
| Lua hook interval | 10,000 instructions |
| CLI pure-Lua timeout | None |
| Session idle TTL | 30 min, lazily enforced |
| Concurrent tasks | 10 per runtime |
| Task wait default | 295 s |
| Task retention | No cleanup while registry remains alive |
| Ingest payload | 64 MiB |
| CLI/blob default stdout limit | 200 MiB |
| Retained subprocess stderr | 1 MiB |
| VFS text read | At most 1 MiB per call |
| VFS listing default | 10,000 entries |
| HTTP JSON response | No explicit body cap |

Rust integration tests under `tests/` exercise CLI behavior, MCP tools and sessions, partial Lua restrictions, persistence, tasks, VFS, ingest, codecs, and transports. Loopback HTTP and Unix socket tests are ignored in environments that do not permit those resources.

Service tests are found by recursively scanning for Lua files with a `tests` path component. Each file receives a fresh runtime. Files are not explicitly sorted by the runner, walk errors are ignored, and test success ultimately depends on the Lua file raising an error (usually through `test.summary`) when assertions fail.

## 15. Proposed architectural improvements

This section is a review backlog, not current behavior.

### P1 — Correct lifecycle, scheduling, and persistence

6. **Replace request-ID ordering with a per-session queue.** Assign a monotonic sequence at receipt, use RAII cleanup, and avoid the global pending-arrivals registry and 5 ms heuristic.
7. **Do not build runtimes under the session-map lock.** Use an entry/future state so an expensive new session does not block unrelated session lookup/creation.
8. **Move blocking work off async executor threads.** Run Lua sessions on dedicated workers or `spawn_blocking`, with bounded concurrency and cancellation.
9. **Unify deadlines.** Make Rust callbacks, task waits, ZIP work, HTTP, and subprocess trees observe one cancellation/deadline abstraction.
11. **Batch metric writes.** Metric updates are atomic SQLite upserts; add batching if wrapper-level write volume becomes significant.
12. **Make cache ownership coherent.** Store values and expiry in the same scope, or define cache as explicitly per-runtime rather than process-shared value/runtime-local expiry.
13. **Manage task lifecycle.** Use a bounded executor, completed-task retention, aggregate result limits, HTTP cancellation, process-group termination, and cancellation on session eviction.

### P1 — Consolidate bootstrap and validation

15. **Make `validate` validate schemas.** Force `capabilities` discovery, report the service directories actually loaded, surface walk errors, and distinguish packs from nested `init.lua` files.
16. **Either implement service introductions or remove the contract.** Initialization should build instructions from loaded `__intro` values if that remains part of service design.

### P2 — Harden resources and observability

18. **Reuse HTTP clients and cap responses.** Add connection pooling, JSON/body limits, richer GraphQL errors with partial data, and true HTTP envelope metadata if required by the service contract.
19. **Replace shell ZIP extraction.** Use an in-process archive library with entry, expanded-byte, compression-ratio, time, and total-disk quotas.
20. **Add aggregate VFS/blob quotas and cleanup controls.** Report truncation and quota errors explicitly.
21. **Unify structured errors.** Return one stable error envelope from Lua through MCP and set MCP error status consistently.
22. **Add execution-log redaction and reliable failure reporting.** Make logging failure policy explicit and avoid recording raw secrets by default.
23. **Remove unbounded process-global registries.** Scope stores, command secrets, and scheduling state to an application object with deterministic cleanup.
24. **Add architecture-focused tests.** Cover schema tampering, wrapper installation, native module loading, MCP metrics, cross-session cache behavior, session eviction with tasks, duplicate/out-of-order request IDs, store concurrency, and timeout gaps.

## 16. Maintaining this document

When core behavior changes:

1. Update the current-implementation sections and remove completed items from the proposal backlog.
2. Update [services/SERVICE-DESIGN.mkd](services/SERVICE-DESIGN.mkd) for service-facing contracts.
3. Keep current behavior and intended future behavior visibly separated.
4. Add or update tests that establish the documented invariant.
5. Run:

```sh
cargo fmt --all -- --check
cargo clippy --offline --all-targets -- -D warnings
cargo test --offline
make test-services
```
