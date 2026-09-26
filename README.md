# munray

Rust host for a persistent Lua runtime exposed through the
official Rust MCP SDK.

```sh
cargo build --release

# Pipe Lua directly to the CLI (there is intentionally no interactive REPL).
printf 'print("hello")\nreturn 6 * 7\n' | target/release/munray

# Or execute a file.
target/release/munray run script.lua

# Start the MCP stdio server and load external service packs.
target/release/munray mcp --svc-dir ./services

# Keep store values and saved Lua snippets across restarts.
target/release/munray --store-path ~/.local/share/munray/store.db \
  --svc-dir ./services mcp

# Push text into an existing MCP session (server id is the MCP process id).
some-command | target/release/munray ingest \
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
`MUNRAY_MCP_HOME` defaults to `$HOME/.local/share/munray`. `--store-path`
(or `MUNRAY_MCP_STORE_PATH`) overrides it. Saved functions, schemas, examples,
metrics, and expiring KV values are durable and shared by runtimes using the
same store path.

The MCP tools are `runLuaScript` (read-only) and
`runGuardedLuaScript` (guarded). Supplying the same `session_id` keeps
Lua globals alive across calls. Guarded calls require MCP Form elicitation by
default. For a harness without elicitation support, start the server with
`munray mcp --delegate-guarded-approval-to-harness` only when that harness
independently confirms or restricts every guarded tool call.
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
| `mcp --delegate-guarded-approval-to-harness` | — | Delegate approval for guarded calls to a harness that lacks MCP Form elicitation; the harness must enforce confirmation or restrictions for every guarded call |

`munray stats` reports wrapped public function availability and usage metrics
from the durable store:

```sh
target/release/munray stats
target/release/munray stats --json
```

## Installation

```sh
make install

# Install a service pack over HTTPS or SSH.
munray svc install https://github.com/<owner>/munray-<service>.git
munray svc install git@github.com:<owner>/munray-<service>.git
```

The binary is installed to `~/.local/bin/munray` by default. `svc install`
clones the service pack into `~/.local/share/munray/services`; a repository
named `munray-<service>` is installed as `<service>`. Override
`INSTALL_BIN_DIR` when invoking Make, or use `--svc-dir` or
`MUNRAY_MCP_HOME` to select the service directory.

### Release binaries

Every `v*` tag publishes installable archives on the GitHub release. Download
the archive for the current version and platform:

| Platform | Archive suffix |
| --- | --- |
| Linux x86_64 | `linux-amd64.tar.gz` |
| Linux ARM64 | `linux-arm64.tar.gz` |
| macOS x86_64 | `darwin-amd64.tar.gz` |
| macOS ARM64 | `darwin-arm64.tar.gz` |
| Windows x86_64 | `windows-amd64.zip` |

On Linux or macOS, extract the archive and put `munray` somewhere on `PATH`:

```sh
tar -xzf munray-<version>-<platform>.tar.gz
install -m 755 munray ~/.local/bin/munray
```

On Windows, extract the ZIP and add the directory containing `munray.exe` to
`PATH`. Each release includes `SHA256SUMS.txt` for verifying downloads.

At runtime, service-directory precedence is `--svc-dir`, then
`MUNRAY_MCP_SVC_DIR`, then `$MUNRAY_MCP_HOME/services`. If `MUNRAY_MCP_HOME` is unset,
it defaults to `$HOME/.local/share/munray`.
