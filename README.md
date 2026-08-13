# munray-mcp

Rust host for a persistent Lua runtime exposed through the
official Rust MCP SDK. Existing service-pack Lua is loaded unchanged.

```sh
cargo build --release

# Pipe Lua directly to the CLI (there is intentionally no interactive REPL).
printf 'print("hello")\nreturn 6 * 7\n' | target/release/munray-mcp

# Or execute a file.
target/release/munray-mcp run script.lua

# Start the MCP stdio server and load external service packs.
target/release/munray-mcp mcp --svc-dir ./services

# Keep store values and saved Lua snippets across restarts.
target/release/munray-mcp --store-path ~/.local/share/munray-mcp/store.json \
  --svc-dir ./services mcp

# Push text into an existing MCP session (server id is the MCP process id).
some-command | target/release/munray-mcp ingest \
  --server <pid> --session <session-id> --json
```

The repository includes the canonical service packs under `services/`:
Compass, Confluence, GCloud, GitLab, Jira, and Terraform. Their original Lua
logic and tests live together in each pack.

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
The store defaults to `$MUNRAY_MCP_HOME/store.json`, where `MUNRAY_MCP_HOME`
defaults to `$HOME/.local/share/munray-mcp`. `--store-path` (or
`MUNRAY_MCP_STORE_PATH`) overrides it. Saved functions, schemas, examples, and
function usage metrics are restored on startup; cache entries intentionally
remain process-local.

The MCP tools are `lua_runLuaScript` (read-only) and
`lua_runMutatingLuaScript` (mutating). Supplying the same `session_id` keeps
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
| `--store-path` | `MUNRAY_MCP_STORE_PATH` | Durable store, saved snippets, and usage metrics; defaults to `$MUNRAY_MCP_HOME/store.json` |
| `--logs-dir` | `MUNRAY_MCP_LOGS_DIR` | Owner-only JSONL execution telemetry |

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

## Migration

Use the Rust binary name `munray-mcp`, rename host environment variables to the
`MUNRAY_MCP_*` forms above, and point `--svc-dir` at this repository’s `services/`
directory. MCP clients should call `lua_runLuaScript` and
`lua_runMutatingLuaScript`. Existing service Lua APIs and test behavior remain
the same; no interactive REPL is provided, so pipe Lua to `munray-mcp` or use the
`run` subcommand.
