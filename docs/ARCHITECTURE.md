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
| MCP session scripts | Untrusted. Each execution uses a separate allowlisted Lua `_ENV` containing pure-Lua helpers, cloned public API tables, and explicitly projected standard-library functions. Its `os` table contains only `date`; it has no `sys`, `io`, `debug`, `package`, `require`, `dofile`, `loadfile`, or `load`. |
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

The executable uses a Tokio multi-thread runtime for the MCP server. MCP admission and execution use `spawn_blocking`: Lua VM construction and each serialized session execution run outside Tokio executor threads. Runtime-local task registries submit work to a lazily-created, process-wide bounded four-worker executor. Constructing an idle runtime creates no task-worker threads.

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
| `svc validate [<name>]` | Constructs a temporary runtime, forces schema discovery and validation, and reports the service-pack directories actually loaded. With a name, loads and validates only that pack. Nested `init.lua` files are reported as modules, not packs. |
| `svc install <repository-url>` | Clone an HTTPS or SSH (`git@host:path`) service repository into the configured service directory, using the repository basename (without `.git`) as its directory name. A `<package-name>-` basename prefix is removed, so `munray-github.git` installs as `github`. Git authentication and transport configuration remain delegated to the local Git client. |
| `svc bootstrap <name>` | Create the schema-valid service-pack skeleton and self-contained `.agents/skills/munray-service-pack/SKILL.md` from compiled assets in the configured service directory. Refuses to overwrite an existing pack unless `--force` is supplied. `svc bootstrap [<name>] --update` replaces only the generated skill for one pack, or for every pack when the name is omitted. |
| `svc bootstrap <name> --mcp-url <url>` | Scan a remote MCP server and create a Lua service pack in a new directory. `--config <path> --server <name>` imports a remote connection from a JSON `mcpServers` entry. |
| `svc refresh <name>` | Rescan the configured remote MCP server and atomically update the catalog of a generated pack, preserving its Lua policy. |
| `svc list` | List service-pack directories with a `src` directory in the configured service directory. |
| `svc uninstall <name> --force` | Remove a service-pack directory after explicit confirmation. `svc delete` and `svc remove` are aliases. |
| `svc test [<name>]` | Find Lua files below any `tests` path and execute each in a new read-only test runtime. With a name, runs only that pack's tests and loads only that pack. Generated `integraion_guarded_tests.lua` files run in guarded mode only when `MUNRAY_RUN_GUARDED=1`; otherwise their skip marker is reported as `SKIPPED`. |
| `ingest` | Send UTF-8 stdin to an already-created MCP session through its Unix socket. |
| `sys list` | Construct a runtime, reflect registered `sys.*` functions, enrich them with core metadata, and render the catalog. Indented text is the default; `--format markdown` and `--format json` provide alternate representations. |
| `stats` | Combine available schema paths with metrics found in the durable store. |

CLI execution permits direct `sys.*` calls and uses guarded mode. Service tests permit direct raw calls, retain the full standard library, and initially use read-only mode. The generated guarded-integration test is the exception only when `MUNRAY_RUN_GUARDED=1`; it also explicitly enables guarded test mode before mutations.

### 3.2 Path resolution

The service directory is resolved in this order:

1. `--svc-dir`
2. `MUNRAY_MCP_SVC_DIR`
3. `$MUNRAY_MCP_HOME/services`
4. `$HOME/.local/share/<package-name>/services`

The store path is resolved from `--store-path`, `MUNRAY_MCP_STORE_PATH`, or `<data-home>/store.db`. Relative store paths are made absolute against the process working directory.

Telemetry is disabled unless `--logs-dir` or `MUNRAY_MCP_LOGS_DIR` is supplied. The package/binary name and default data-directory leaf derive from Cargo package metadata; the canonical product name is in `Cargo.toml`.

The CLI handles `svc` subcommands before requiring a persistent store path for other commands. Remote MCP bootstrap and `svc refresh` use the resolved store path when available and fall back to an in-memory store when no path can be resolved.

## 4. Source map

| Area | Primary files | Responsibilities |
| --- | --- | --- |
| CLI/configuration | `src/main.rs` | Argument parsing, path resolution, command routing, service test runner. |
| MCP server | `src/mcp.rs` | Tools, elicitation, sessions, ordering, timeout selection, response encoding. |
| External MCP client | `src/mcp_client/` | MCP transports, OAuth, catalog discovery and refresh, and generated Lua wrappers. |
| Lua runtime | `src/runtime.rs` | VM construction, raw registration, preload, execution, conversion, restrictions. |
| Durable storage | `src/storage.rs` | SQLite lifecycle, KV expiry, metrics, snippets, schema initialization, and Lua storage bridges. |
| Service loading | `src/services.rs` | Deterministic source/example discovery and execution, with a report of loaded packs and nested modules. |
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
| Runtime/application | SQLite connection | Each runtime owns its mutex-protected SQLite connection. WAL coordinates concurrent runtimes and processes; dropping the runtime closes its connection. |
| Process-global (bounded compatibility lookup) | command-secret registry | Holds at most 1,024 active command-secret definitions and prunes weak references when a runtime is dropped. |
| `McpServer` | session map, service/store paths, TTL, optional logger | Shared across cloned server handlers. |
| `Session` | one mutex-protected `LuaRuntime`, per-session FIFO queue, last-used time | At most 64 retained MCP sessions; idle entries are lazily evicted and eviction cancels runtime tasks. |
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
8. For MCP runtimes, build a separate session `_ENV` containing pure Lua facilities, cloned public API tables, and allowlisted standard-library projections (`os.date` only). Raw/internal globals (including `sys`, regardless of schema metadata) and other host-facing standard-library functions are omitted.

The modular preload files are the sole Lua bootstrap implementation. Their explicit load order in `runtime.rs` is the dependency order between core Lua namespaces.

### 6.1 Direct-raw and standard-library modes

| Runtime constructor/use | Direct `sys.*` | User-visible standard library |
| --- | --- | --- |
| MCP session (`new_mcp`) | Guarded | Partially restricted |
| CLI (`new_persistent`) | Allowed | Partially restricted |
| General library runtime (`new`) | Allowed | Partially restricted |
| Service test (`new_with_options(..., true)`) | Allowed | Full |

Service source and persisted snippets load before restrictions are applied. Wrapped external functions temporarily restore the full `io`, `os`, `package`, and `require` values captured at bootstrap.

## 7. Service-pack integration

The service-pack layout, loading contract, schema metadata, examples, and public raw-API contract are maintained in [services/SERVICE-DESIGN.mkd](services/SERVICE-DESIGN.mkd). Packs are loaded during runtime construction; a missing service directory leaves only core APIs available. `svc validate` builds a temporary runtime and forces capability discovery, so invalid pack metadata fails validation.

The loader records accepted pack directories and nested `init.lua` modules for `validate` reporting. MCP initialization appends non-empty `__intro` strings from successfully loaded packs under **Available service integrations**. Dynamic snippet changes invalidate capability discovery, so the next `ctx_init()`, `schema()`, or `examples()` observes the current snippet functions.

The runtime loader, `svc list`, and bulk `svc bootstrap --update` use the same directory discovery. Discovery follows links to service pack directories and uses each link's name and path in the configured directory.

`schema(target, ...)` accepts exact namespace or function paths. Namespace responses include sorted, fully qualified descendant names in `nested_namespaces` when present. Function responses contain one descriptor and the namespace-local types referenced by that function, including dependencies of those types. A multi-target call returns schemas keyed by path. A failed lookup returns `(nil, err)` for the call.

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

On the first call for a session ID, the server records a building entry under the session-map lock, then constructs the runtime and loads service packs in `spawn_blocking` after releasing that lock. Concurrent callers wait on that entry's completion rather than duplicate construction. A missing `session_id` causes the server to generate a UUID, retain that session, and return the UUID in the tool payload; the caller can reuse the returned ID later.

The runtime stores the MCP process ID in `__runtime.server_id`, which `ctx_init()` exposes for ingest workflows.

Sessions expire after 30 minutes of inactivity, but cleanup is **lazy**: expiration is checked only while admitting an execution. There is no periodic cleanup loop and no explicit session-close API. An in-flight `Arc` reference prevents eviction. Admission is capped at 64 retained sessions, including generated IDs for calls that omit `session_id`.

### 8.3 Same-session ordering

Independent sessions execute concurrently. Same-session calls reserve a monotonic sequence in a session-local FIFO queue when admitted. The reservation is RAII-managed: a rejected guarded call, failed build, or dropped request marks its sequence cancelled and advances the queue head, so it cannot strand later work. Request IDs are not used for scheduling and there is no process-global arrival registry or timing heuristic.

### 8.4 Guarded elicitation

If the client advertises form elicitation, the guarded tool requests an `Approve`/`Reject` decision before execution. Decline, cancel, or any accepted value other than `Approve` returns a `REJECTED_BY_GUARD` payload and does not execute code.

If an advertised form elicitation request fails, the call returns
`REJECTED_BY_GUARD`. When form elicitation is unavailable, the call returns
`ELICITATION_UNAVAILABLE` unless the server was started with
`--delegate-guarded-approval-to-harness`. With that flag the guarded tool
executes and the harness is responsible for confirming or restricting its calls.

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

An uncaught execution failure is encoded in the stable `error` envelope (`code`, `message`, `recoverable`, and `context`) while the tool call retains its response payload. Empty code and pre-execution/logging failures return an MCP tool error.

## 9. Lua execution, deadlines, and value conversion

### 9.1 Execution

Before each execution the runtime:

1. sets the current `ExecutionMode`;
2. clears the shared print buffer;
3. installs an instruction hook when a timeout was supplied;
4. enters a thread-local deadline scope; and
5. evaluates the code as a Lua chunk with `mlua::Chunk::eval`.

The hook checks every 10,000 Lua instructions. MCP supplies a timeout; the local CLI currently calls `execute` without an overall Lua timeout, so pure Lua code can run indefinitely there.

The thread-local deadline constrains synchronous nested operations, including CLI capture, HTTP, blob capture, command secrets, task waits, and VFS ZIP subprocesses. Nested operations clamp their requested timeout to the active deadline. Async task starts snapshot the caller's absolute deadline and restore it in the worker, so CLI/HTTP work cannot outlive the originating MCP deadline. Task cancellation is additionally propagated to CLI and HTTP task loops.

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

After trusted loading, Rust walks schema namespace tables and records immutable operation metadata in a per-runtime registry. It derives each operation path as `<fully-qualified namespace>.<function name>`, then replaces each matching public function with a Rust closure that captures the original Lua function, mutation policy, return contract, and operation path. It rejects captured guarded functions in read-only mode and wraps iterators so each step has the same authorization.

Mutation policy is never read from mutable Lua descriptors at call time. Session code receives cloned public tables, so descriptor/function reassignment cannot alter trusted globals or registry entries. Human-approved `snippets.save` and `snippets.delete` update the Rust registry and refresh those public clones immediately.

### 10.2 Raw guard

Every raw Rust callback is replaced with a Rust guard closure. The guard consults Rust-owned bootstrap/direct-access/depth state and returns `(nil, RAW_OUTSIDE_SCHEMA)` unless direct raw access is enabled or an RAII scope from a registered public wrapper is active. Iterator steps enter a separate Rust scope. Session environments do not expose `sys` at all, even if trusted legacy data added schema metadata to that raw table. Approved snippet bodies still execute in trusted globals and may call `sys.*` through their wrapper's raw scope.

There is no Lua wrapper installer or Lua raw-context counter.

### 10.3 Standard-library restrictions

Non-test VMs use mlua's safe standard-library constructor, which prevents native/C module loading. MCP session chunks execute with a separate allowlisted `_ENV`; it contains pure Lua primitives, cloned public API tables, and explicitly projected standard-library functions, but not full host-facing standard libraries, raw globals, package loading, or `load`/file loaders.

`SESSION_LIBRARY_EXPORTS` in `src/runtime.rs` is the declarative function-export allowlist. Currently, only `os.date(format?, time?)` is exposed, in both read-only and guarded execution, with standard Lua formatting, UTC (`!`), and table (`*t`) behavior. `os.time`, `os.clock`, `os.difftime`, `os.getenv`, `os.execute`, `os.exit`, `os.remove`, `os.rename`, `os.setlocale`, and `os.tmpname` remain unavailable. Every environment refresh clears blocked globals, then creates fresh projection tables containing only the named functions, without source metatables. Missing/non-function exports fail runtime construction or refresh. Projection libraries are excluded from automatic public-table cloning, even if they have schema metadata. Session table mutation cannot change trusted library tables; snippet save/delete refreshes reapply the same allowlist. Extending it requires adding function names to the policy, not new projection logic.

Trusted core/service code retains its trusted global environment; this change does not alter CLI or service-test library access.

This is a Lua-language boundary, not OS process isolation. Trusted service packs and approved snippets intentionally retain the safe VM's host-facing Lua facilities; architectural security must not treat them as contained to `sys.*` or the VFS.

### 10.4 CLI allowlist

The raw CLI and command-secret implementations require exact command-name membership in the aggregated allowlist. The default list is empty. This protects accidental raw CLI use, but it is not a command sandbox:

- allowing a shell permits arbitrary shell behavior;
- `cwd` may refer to arbitrary host paths;
- child processes inherit the server environment; and
- trusted service code can use restored standard-library facilities outside the raw CLI path.

## 11. Core Lua API and raw facilities

### 11.1 Public API contract

The complete pack-facing raw and public Lua API contract is maintained in [services/SERVICE-DESIGN.mkd](services/SERVICE-DESIGN.mkd). This document records implementation and operational behavior of those facilities below. `helpers.collect` materializes only each iterator step's primary return value; `helpers.collect_tuples` is the opt-in helper for packed multi-return rows. `errutil` is intentionally internal and has no schema.

The public `base64` namespace uses standard RFC 4648 Base64 with canonical padding. `base64.encode` accepts a Lua byte string and `base64.decode` returns one. Both are installed before trusted service sources load and are available in service code, MCP pack configuration, and read-only sessions. Lua strings retain arbitrary bytes inside the runtime. Encode binary results before sending them through the UTF-8 JSON interface.

### 11.2 CLI and process capture

Synchronous CLI calls poll the child every 10 ms, drain stdout/stderr concurrently, and kill the immediate child on timeout. Stdout is capped at 200 MiB by default and stderr retention at 1 MiB; readers continue draining after the retained cap to avoid pipe deadlock. Child process groups are not managed, so descendants can outlive a killed parent.

Text mode decodes stdout lossily as UTF-8. JSON mode parses stdout as JSON. Nonzero exits return `CLI_ERROR`; timeout and output overflow use separate error codes.

### 11.3 HTTP and GraphQL

The transport reuses one blocking `reqwest::Client` connection pool; each request sets its own timeout. HTTP options support query values, JSON body, map or ordered-list headers, auth references, and timeout. Normal JSON responses are capped at 16 MiB by default and 64 MiB maximum through `max_response_bytes`; `response_mode="http_envelope"` returns status, headers, and decoded body.

HTTP behavior includes:

- only HTTP(S) base URLs with a host;
- relative request paths appended to any base path prefix;
- JSON decoding for normal requests;
- one command-bearer refresh/retry after HTTP 401;
- one HTTP 429 retry when `Retry-After` is numeric and no more than 30 seconds; and
- a 4 KiB error-body message, although normal JSON responses are read without an explicit body-size cap.

HTTP pagination is lazy and supports `page`, `offset`, opaque `token`, and same-origin cursor-link modes. Cursor links must preserve scheme, host, port, and configured base-path prefix.

GraphQL uses HTTP POST and supports data or envelope response mode plus cursor/offset pagination. The GraphQL envelope is the decoded GraphQL response body; callers requiring transport metadata can use HTTP's `http_envelope` response mode. A non-empty GraphQL `errors` array becomes `GRAPHQL_ERROR` whose message retains the returned errors and partial data.

### Remote MCP integrations

The default `mcp-client` Cargo feature adds a separate client used by catalog
scans and generated tool wrappers. The client supports Streamable HTTP and
legacy SSE. It establishes an MCP session for each scan or tool call.
Before scanning for a new pack, bootstrap rejects names occupied by Lua
globals from the core runtime or installed service packs. It loads installed
packs for this check using the same optional store path as catalog refresh.
The configured MCP origin controls where bearer credentials can be sent,
including legacy SSE message endpoints and redirects.

The generated Lua entrypoint reads the local `mcp-catalog.json` and evaluates
`config.lua` through `sys.mcp.config` during pack loading. Catalog refresh
evaluates the same configuration with the trusted core Lua APIs initialized
through the service runtime's bootstrap. It uses the normal store path
resolution for persistent APIs such as `kv.get`. With no configured path or
data home, it uses an in-memory store. Refresh does not load other service
packs. The generated entrypoint itself performs no network requests. The
Lua template builds one schema-backed function per enabled catalog entry.
It uses `sys.mcp.auth` for the configured connection and `sys.mcp.tool_call`
for each outbound tool invocation. The
normal execution-mode gate applies before the function can start a network
request. Tool arguments are JSON objects and results preserve MCP content and
structured content. Calls inherit the active Lua deadline.

OAuth accesses sessions through the `CredentialStore` interface. A store
session holds exclusive access while OAuth reads, refreshes, or replaces its
credentials. The JSON implementation stores one file per integration and
connection settings outside the service directory and uses a file lock to
coordinate calls across processes. OAuth discovery requires a resource string
that exactly matches the MCP endpoint for challenge and endpoint-specific
metadata, or the origin for root metadata. Candidates with invalid or
mismatched resources are skipped. The session retains the accepted resource for OAuth
requests while MCP requests use the configured endpoint.
Stored credentials are replaced only after
a successful authorization, so cancelling a scope upgrade preserves the old
session. A login started by a Lua call in the
long-running MCP server can complete after that call's deadline. The client
does not replay a dispatched tool call after an authorization rejection or a
transport failure.

### 11.4 Background tasks

Each runtime has one task registry backed by the shared lazily-created four-worker executor. A task has a UUID, timestamps, cancellation flag, and one of four states: `running`, `completed`, `failed`, or `cancelled`.

Current behavior:

- at most 10 running tasks are admitted per runtime;
- each runtime submits work to a bounded four-worker executor with a bounded queue;
- `async_task.cancel` is a guarded operation because it mutates task state; cancellation is observed by CLI and HTTP task loops;
- `async_task.wait` polls every 20 ms, defaults to 295 seconds, and is clamped by the active execution deadline;
- completed records are retained for five minutes; and
- task results are limited to 10 MiB before retention.

Session eviction explicitly cancels all runtime tasks. Subprocesses run in their own process group on Unix, so timeout/cancellation terminates descendants as well as the immediate child.

### 11.5 Secrets and auth

Secret and auth references are Lua tables, not opaque userdata. Environment references store an environment-variable name. Command references store an ID into a process-global Rust registry.

Command-secret rules:

- command must be on the runtime CLI allowlist;
- timeout defaults to 10 seconds and is limited to 30 seconds;
- successful stdout is trimmed, must be non-empty UTF-8, and is cached for `ttl_s` (default one hour); and
- a command-backed bearer cache is invalidated once after HTTP 401.

The bounded command registry is pruned when a runtime drops; stale weak-allowlist definitions are removed deterministically and cannot resolve after runtime destruction.

### 11.6 VFS and blobs

Each runtime owns a temporary VFS root. VFS paths must be non-empty and free of parent/root/prefix components after leading `/` characters are discarded; therefore `/logs/job.txt` is equivalent to `logs/job.txt`. They are limited to ASCII alphanumerics plus `.`, `_`, `/`, and `-`.

The VFS provides directory creation/removal, text/blob writes, text reads, metadata, recursive/nonrecursive listing, ZIP extraction/previews, and exposure bundles. Scripts in read-only mode can create directories, write text, and remove files or directory trees in their runtime's VFS. `vfs.remove` rejects paths that resolve to the VFS root before any deletion. `vfs.write_text` creates missing parent directories. `vfs.expose` requires guarded mode because it creates host-visible copies outside the VFS root.

ZIP conversion uses the in-process `zip` reader. It rejects unsafe paths and enforces 1,000 entries, 100 MiB expanded bytes, a 100:1 compression-ratio limit, the active execution deadline between entries, preview limits, and the runtime VFS quota. Exposure bundles remain alive until the runtime drops.

Blob bytes are held in an in-memory map and represented in Lua by userdata. The default per-capture limit is 200 MiB and a runtime-wide 512 MiB aggregate cap returns `BLOB_QUOTA_EXCEEDED`. Each capture reserves its bounded buffer from that aggregate before CLI/HTTP bytes are read, so caller-controlled limits cannot allocate beyond the quota before rejection. VFS writes and ZIP extraction enforce a 512 MiB aggregate cap and return `VFS_QUOTA_EXCEEDED`. `vfs.remove` reclaims VFS quota, and all runtime-local VFS/blob state is released at runtime teardown.

### 11.7 Ingest and local IPC

On Unix, `mcp` binds `<temp-dir>/<package-name>-ingest-<pid>.sock`, removes a pre-existing path with that name, and sets socket mode `0600`.

The protocol is:

1. one JSON header line containing operation, session ID, and byte count;
2. exactly that many payload bytes; and
3. one JSON response line.

Payloads are limited to 64 MiB and must be UTF-8. The target session must already exist. The text is written below that runtime's VFS and associated with a random `ing_<32 hex>` token. Each call to `ingest.get` in that session reads the current contents of the VFS file. Scripts can edit or remove the file using the VFS APIs.

The listener uses detached native threads. Dropping its guard removes the socket path but does not provide a coordinated thread-shutdown protocol.

## 12. Persistence, snippets, metrics, and statistics

### 12.1 Store representation

The durable store is SQLite, implemented in `src/storage.rs`. It owns independent `kv_entries`, `metrics`, and `snippets` relations and creates them transactionally on open. Connections use WAL, normal synchronous durability, a 64 MiB page cache, in-memory temporary storage, and foreign-key enforcement. A process reuses one mutex-protected connection per absolute database path; SQLite coordinates writers in other processes.

Generic KV rows retain JSON text, content type, timestamps, and an optional expiry. Expired KV rows are hidden at `expires_at_s <= now` and lazily removed during get, keys, and count. There is no core cache API or cache relation: callers use a normal durable namespace and set expiry themselves. Metrics and snippets are core-owned relations and are not reachable through generic KV.

### 12.2 Persisted snippets

Complete snippet rows are restored during startup. The public `snippets.save` definition uses `namespace` and `name` (for example, `{namespace="math", name="fibonacci"}` installs `math.fibonacci`); the durable store uses an internal dotted identifier. Its `code` may be a function expression, a chunk that returns a function, or a named Lua function declaration. Function text is compiled in the global environment, namespaces are created dynamically, descriptors are attached, and security wrappers are reinstalled. Snippets default to `readonly = true` unless schema text says otherwise.

Installing/deleting a snippet changes only the current Lua runtime immediately. `sys` is reserved and cannot be a snippet namespace, although trusted snippet code may call `sys.*`. Deleting the final snippet from a snippet-created namespace prunes that empty namespace, removes its cloned root from the current MCP session environment, and makes it no longer discoverable. Other existing sessions share its durable records but do not install/remove the corresponding Lua function until they are recreated or explicitly updated themselves.

### 12.3 Function metrics and `stats`

Schema wrappers intend to increment:

- `fn.<path>.calls`;
- `fn.<path>.err`; and
- `fn.<path>.blocked`.

Metric increments are buffered by a runtime for one Lua execution, then atomically flushed as a SQLite transaction. This preserves wrapper-level accounting for MCP and CLI calls without synchronous SQLite contention in high-frequency loops.

`stats` creates a runtime to discover currently available function paths, reads historical metric records from the store, and reports both available functions and metrics for functions that no longer exist.

## 13. Telemetry and errors

### 13.1 Execution logging

When enabled, execution logging appends JSON lines to `<logs-dir>/executions.jsonl`. Each entry includes timestamp, session, mode, full Lua code, output, result, error, and duration. Unix creation modes are `0700` for a newly-created directory and `0600` for the file.

Telemetry redacts code, output, result, and error values by default. Set `MUNRAY_MCP_LOG_RAW=1` only for an explicitly trusted diagnostic environment. Logger creation and write failures propagate on both CLI and MCP, and CLI logs failed executions after preserving their captured output.

The logger mutex is per `Logger` instance; it is not an inter-process file lock.

### 13.2 Error forms

Expected raw/public failures generally use `(nil, err)` with `code`, `message`, `recoverable`, and optional context/hints. `errutil` can translate and sanitize transport errors before they become public.

Iterator transport failures are thrown from the raw iterator. Helper consumers catch them and coerce them to a public `ITERATION_FAILED` shape.

Uncaught Lua/embedding errors are normalized at the MCP boundary into `EXECUTION_FAILED` envelopes with `code`, `message`, `recoverable`, and `context`. Pre-execution and logging failures use MCP tool errors consistently.

## 14. Current limits and verification

`rust-toolchain.toml` pins Rust 1.99.0 with rustfmt and Clippy for development and CI. Local `cargo`/`rustc` commands must use rustup shims (not a standalone compiler earlier in `PATH`) to honor this pin. Both the CI test job and release-build matrix run `rustup show` after checkout to install/select that toolchain; release builds then add their matrix target. Update the pin explicitly when upgrading Rust so local and CI lint rules stay aligned.

| Resource/behavior | Current value |
| --- | --- |
| MCP call timeout | 60 s default, clamped to 100 ms–10 min |
| Lua hook interval | 10,000 instructions |
| CLI pure-Lua timeout | None |
| Session idle TTL | 30 min, lazily enforced |
| Concurrent tasks | 10 per runtime; four process-wide worker threads, created on first task |
| Task wait default | 295 s |
| Task retention | No cleanup while registry remains alive |
| Ingest payload | 64 MiB |
| CLI/blob default stdout limit | 200 MiB (also reserved against the 512 MiB blob quota before capture) |
| Retained subprocess stderr | 1 MiB |
| VFS text read | At most 1 MiB per call |
| VFS listing default | 10,000 entries |
| HTTP JSON response | 16 MiB default; 64 MiB maximum |
| Runtime VFS/blob aggregate | 512 MiB each |
| ZIP entries/expanded bytes/ratio | 1,000 / 100 MiB / 100:1 |

Rust integration tests under `tests/` exercise CLI behavior, MCP tools and sessions, partial Lua restrictions, persistence, tasks, VFS, ingest, codecs, and transports. Loopback HTTP and Unix socket tests are ignored in environments that do not permit those resources.

Service tests are found by recursively scanning for Lua files with a `tests` path component. Each file receives a fresh runtime. Files are not explicitly sorted by the runner, walk errors are ignored, and test success ultimately depends on the Lua file raising an error (usually through `test.summary`) when assertions fail.

## 15. Maintaining this document

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
