# munray-mcp

Rust host for a persistent Lua runtime exposed through the
official Rust MCP SDK.

```sh
cargo build --release

# Pipe Lua directly to the CLI (there is intentionally no interactive REPL).
printf 'print("hello")\nreturn 6 * 7\n' | target/release/munray-mcp

# Or execute a file.
target/release/munray-mcp run script.lua

# Start the MCP stdio server and load external service packs.
target/release/munray-mcp mcp --svc-dir ./services

# Keep store values and saved Lua snippets across restarts.
target/release/munray-mcp --store-path ~/.local/share/munray-mcp/store.db \
  --svc-dir ./services mcp

# Push text into an existing MCP session (server id is the MCP process id).
some-command | target/release/munray-mcp ingest \
  --server <pid> --session <session-id> --json
```

The repository includes the canonical service packs under `services/`:
Their original Lua logic and tests live together in each pack.

```sh
# Build, lint, run Rust tests, then run every service-pack Lua test.
make test-all

# Validate or test only the bundled service packs.
make validate
make test-services

# Start MCP with the bundled packs.
make mcp
```

`--svc-dir` points at the existing service-pack tree. Rust replaces the
host application; it does not translate or alter service Lua source.
The SQLite store defaults to `$MUNRAY_MCP_HOME/store.db`, where
`MUNRAY_MCP_HOME` defaults to `$HOME/.local/share/munray-mcp`. `--store-path`
(or `MUNRAY_MCP_STORE_PATH`) overrides it. Saved functions, schemas, examples,
metrics, and expiring KV values are durable and shared by runtimes using the
same store path.

The MCP tools are `runLuaScript` (read-only) and
`runGuardedLuaScript` (guarded). Supplying the same `session_id` keeps
Lua globals alive across calls.
Idle sessions are evicted after 30 minutes; independent sessions execute in
parallel while calls reusing one session are processed FIFO.

The runtime includes schema discovery, CLI/HTTP/GraphQL transports,
page/offset/cursor iterators, async CLI tasks, optional persistent storage,
VFS, binary-safe CLI/HTTP blobs, execution timeouts, raw API introspection,
and ingest. Unix ingest sockets are created with owner-only permissions.

## Configuration

| Option | Environment | Purpose |
| --- | --- | --- |
| `--svc-dir` | `MUNRAY_MCP_SVC_DIR` | Service-pack directory; defaults to `$MUNRAY_MCP_HOME/services` |
| `--store-path` | `MUNRAY_MCP_STORE_PATH` | SQLite durable store, saved snippets, expiring KV values, and usage metrics; defaults to `$MUNRAY_MCP_HOME/store.db` |
| `--logs-dir` | `MUNRAY_MCP_LOGS_DIR` | Owner-only JSONL execution logging |

`munray-mcp stats` reports wrapped public function availability and usage metrics
from the durable store:

```sh
target/release/munray-mcp stats
target/release/munray-mcp stats --json
```

## Installation

```sh
make install
make services-install
```

The binary is installed to `~/.local/bin/munray-mcp` by default. Development
service links are installed under `~/.local/share/munray-mcp/services`. Override
`INSTALL_BIN_DIR` or `MUNRAY_MCP_HOME` when invoking Make if desired.

At runtime, service-directory precedence is `--svc-dir`, then
`MUNRAY_MCP_SVC_DIR`, then `$MUNRAY_MCP_HOME/services`. If `MUNRAY_MCP_HOME` is unset,
it defaults to `$HOME/.local/share/munray-mcp`.
