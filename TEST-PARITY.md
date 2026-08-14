# Test parity

Rust tests are organized by behavioral contract instead of mirroring implementation-file
names. This table records the coverage mapping.

| Legacy area | Rust coverage | Status |
| --- | --- | --- |
| CLI help, stdin execution, validation, raw listing | `tests/cli.rs`, `Makefile` | Covered |
| Interactive REPL and shell completion | — | Intentionally omitted by product requirement |
| MCP initialization, tools, sessions, FIFO, parallel sessions | `tests/mcp.rs` | Covered |
| MCP timeout parsing and Lua interruption | `tests/timeout.rs`, `tests/process_timeout.rs` | Covered |
| Unix ingest framing and session targeting | `tests/ingest.rs`, ignored socket test in `tests/mcp.rs` | Covered |
| CLI execution, allowlists, timeout, output bounds | `tests/process_timeout.rs`, `tests/tasks.rs` | Covered |
| HTTP requests, retries, URL composition, pagination | `tests/http.rs`, unit tests in `src/http.rs` | Covered |
| GraphQL requests and pagination | `tests/http.rs`, service tests | Covered |
| Secrets, auth, TTL cache, 401 refresh | unit tests in `src/secrets.rs`, HTTP integration tests | Covered |
| Async task status/result/wait/cancel/concurrency limit | `tests/tasks.rs` | Covered |
| Store CRUD, cache, snippets, persistence | `tests/store.rs`, `tests/snippets.rs`, `tests/persistence.rs` | Covered |
| Blob capture and size limits | `tests/blob.rs`, `tests/process_timeout.rs` | Covered |
| VFS traversal, expose, text conversion, ZIP | `tests/vfs.rs`, `tests/vfs_zip.rs` | Covered |
| Standard-library isolation and raw-context enforcement | `tests/sandbox.rs`, `tests/mcp.rs` | Covered |
| Capabilities, schemas, examples, service metadata | bundled `services/*/tests`, `tests/snippets.rs` | Covered |
| JSON/YAML codecs and multiple return values | `tests/codecs.rs`, `tests/results.rs` | Covered |
| Execution logging and stats | `tests/logging.rs` | Covered |
| Service-pack behavior | 22 bundled Lua tests under `services/*/tests` | Covered unchanged except host rename text |

Network and Unix-socket tests are marked ignored for ordinary managed-sandbox
runs. Run them on a normal host with:

```sh
make test-ignored
```

The complete local verification command is:

```sh
make test-all
```
