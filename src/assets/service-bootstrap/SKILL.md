---
name: munray-service-pack
description: Build, validate, and test a Munray Lua service pack without access to Munray source code.
---

# Munray service-pack development

Use this skill when implementing or changing the service pack in this directory.
It is self-contained: use the generated pack files, the `munray` executable, and
its command output. Do **not** require access to Munray's source tree or internal
design documents.

## Non-negotiable rules

- A service pack is **trusted host code**, not a sandboxed plugin. Never fetch,
  generate, or execute untrusted Lua. Never log, print, return, or persist raw
  secrets.
- Keep loading side-effect free. Do not make network calls, resolve credentials,
  or run commands while `src/init.lua` or another module is loading.
- Public operations are stateless: pass identifiers, filters, configuration, and
  payloads explicitly. Return plain Lua tables only; do not return metatables.
- `sys.*` is an internal implementation API. Public pack functions must be
  schema-backed wrappers. Do not expose `sys` on a public namespace.
- Do not inspect, infer, or invent raw primitive signatures. At the beginning of
  work, run this exact command against the target Munray installation:

  ```sh
  munray sys list --format markdown
  ```

  Treat that command's output as the version-specific reference for `sys.*`
  signatures, options, return values, and primitive descriptions. Re-run it if
  Munray is upgraded.
- Prefer an existing service CLI as the backend wherever it can provide the
  required operation. First independently investigate the service's official
  tooling and the target environment for a suitable CLI. If that does not
  identify a usable CLI, ask the user whether one is available. A CLI that
  proxies API requests and manages authentication is the preferred API backend;
  use it as the proxy rather than reimplementing its authentication or making
  raw API requests. Likewise, use a CLI-supported temporary-auth-token flow
  when available. If no such flow can be found during investigation, ask the
  user about it. Raw HTTP or GraphQL API calls are a last resort, only after
  these CLI options have been exhausted.

## Pack layout and load order

A bootstrapped pack has this layout:

```text
<service>/
  .agents/
    skills/
      munray-service-pack/
        SKILL.md
  src/
    init.lua
    resource.lua
  examples/
    <service>.lua
  tests/
    capabilities_test.lua
```

`src/init.lua` is the sole entry point and loads before every other `src/*.lua`
file. Other source files load in lexical order. Define the service root and
public namespace tables in `init.lua`; implement wrappers in neighboring files.

The service name and root Lua namespace must start with a lowercase ASCII letter
and then use only lowercase ASCII letters, digits, or underscores. Keep the
service name in sync across directory name, root table, and schema `service`.

## Workflow

1. Read this file and the generated `src/init.lua`, `src/resource.lua`, test, and
   example. Replace every `<...>` placeholder and remove `NOT_IMPLEMENTED`.
2. Investigate an existing official or installed CLI for the service, including
   whether it can proxy API requests, handle authentication, or mint temporary
   auth tokens. If the investigation does not find a usable CLI or token flow,
   ask the user before choosing a raw API implementation.
3. Run `munray sys list --format markdown`. Prefer the smallest suitable
   `sys.cli.*` primitive for a usable CLI; choose an HTTP or GraphQL primitive
   only as a last resort. Do not shell out or use host APIs as a substitute.
4. Define a small read-only public operation first, including input validation,
   a public error translation policy, schema metadata, a capability test, and a
   runnable example.
5. Run `munray validate --svc-dir <services-dir>` and
   `munray test --svc-dir <services-dir>` after each coherent change.
6. Add mutations only after the read path is correct. Mark each mutation
   `guarded = true` in its function schema; do not implement Lua-side permission
   checks and do not derive mutation policy from an HTTP method or CLI verb.

Do not make external/network tests run by default. Capability and unit-style
fixtures must run offline. Add integration tests only when explicitly requested
or when credentials, endpoint, and a safe test target have been supplied.

## Public API contract

Every public namespace table has a `__schema`. The root schema may have an empty
`functions = {}` list when it only advertises child namespaces through
`resources`. Every function descriptor must include all of:

```lua
{
  name = "get",
  signature = "(id, opts?)",       -- argument list only; begins with "("
  description = "Fetch one resource.",
  guarded = false,
  returns_contract = "core.result",
  returns_typed = {
    { name = "result", type = "Resource" },
    { name = "err", type = "core.error|nil" },
  },
}
```

Use these contracts exactly:

- Ordinary synchronous operation: `returns_contract = "core.result"`; return
  `(result, nil)` or `(nil, err)`.
- Lazy list: `returns_contract = "core.iter"`; also set `yields = "TypeName"`
  and make `returns_typed[1].type` equal to `"Iterator"`.
- Async starter: `returns_contract = "core.async.result"`; return a typed
  `task_id` string and declare:

  ```lua
  returns_typed = { { name = "task_id", type = "string" } },
  async = { kind = "task", handle = "task_id" },
  ```

For each parameter, provide a `params` entry with `name`, `type`, and
`optional`. Describe structured option tables using the parameter's `schema`
field. Add compact named types under `types`, normally with a `shape` string.
Keep a schema close to its public wrappers; it is both the discoverable contract
and the enforcement boundary.

A minimal ordinary wrapper looks like this:

```lua
local request = sys.http.request -- select the actual primitive/signature from sys list

function acme.widget.get(id)
  if type(id) ~= "string" or id == "" then
    return nil, {
      code = "VALIDATION_FAILED",
      message = "id must be a non-empty string",
      context = { field = "id" },
      recoverable = false,
    }
  end

  local value, err = request("GET", "https://api.example.invalid", "/widgets/" .. id)
  if err then
    return nil, translate_error(err)
  end
  return normalize_widget(value), nil
end
```

Use local helper functions such as `translate_error` and `normalize_widget` to
keep raw transport data out of the public contract. Public errors are tables
with a stable `code`, a human-readable `message`, optional safe `context` and
`hint`, and `recoverable` when retry is appropriate. Do not return raw tool,
arguments, stdout, stderr, exit codes, authorization headers, or credentials.

## Lists and asynchronous work

List functions must return generic-for-compatible lazy iterators. Do not
materialize a large list in the wrapper. Consumers use:

```lua
local items, err = helpers.collect(iterator, { limit = 100 })
```

An iterator ends by returning `nil` as its first value. If fetching a later page
fails, it throws a structured public error; do not stringify raw transport
errors. Use the actual HTTP or GraphQL pagination options shown by `sys list`.

For delayed work, start it with the applicable `sys.cli.start_*`,
`sys.http.start_request`, or `sys.graphql.start_request` primitive from the
reference output. Return the task id. Callers use `async_task.status`,
`async_task.result`, or `async_task.wait`; packs do not create their own Lua
background threads.

## Transports, credentials, and binary data

After completing the required CLI investigation, choose the implementation
primitive from `munray sys list --format markdown`:

- **CLI:** add every executable to `<service>.__allowed_cli_commands`; use the
  structured argument array accepted by `sys.cli.*`; never use `os.execute`,
  `io.popen`, or a shell string. Prefer JSON output when available.
- **HTTP/GraphQL:** use `sys.http.*` or `sys.graphql.*` only when no suitable
  CLI backend, CLI API proxy, or CLI temporary-token flow is available; preserve
  structured decoded responses and normalize them at the wrapper boundary.
- **Secrets and auth:** create opaque references with `sys.secrets.*`, then
  construct auth with `sys.auth.*`, exactly as documented by the reference
  output. Pass the reference only through transport options. Never read an
  environment variable directly in pack code.
- **Binary responses:** use `sys.blob.*` and write opaque blobs with
  `sys.vfs.write_blob`; never coerce blob bytes to Lua strings.
- **VFS:** use only safe relative VFS paths. VFS is runtime-local scratch
  storage, not a durable service data store.

The active caller deadline limits transport work. Set a transport timeout only
when the upstream operation needs a smaller bound; it cannot extend the caller
deadline.

## Examples and tests

- Add a short runnable service-level example in `examples/<service>.lua`.
- Use inline `examples = [[...]]` for function-specific usage where valuable.
- Keep examples focused and do not add test-only execution gates to them.
- Keep `tests/capabilities_test.lua` and update it when operation names change.
  It must verify that schemas are discoverable and that the implementation's
  expected result/error shape is truthful.
- For deterministic tests, stub the wrapper helper or use a fixture. External
  integration tests are opt-in and must fail clearly when prerequisites are
  absent.

## Completion checklist

Before considering the pack complete:

```sh
munray validate --svc-dir <services-dir>
munray test --svc-dir <services-dir>
```

Verify all of the following:

- no placeholders or `NOT_IMPLEMENTED` remain;
- every public function has complete schema metadata;
- all mutations are `guarded = true`, and reads are `guarded = false`;
- return contracts match actual behavior;
- list operations are lazy iterators;
- secrets and raw transport diagnostics cannot reach public output;
- CLI options, including API-proxy and temporary-token support, were
  independently investigated; the user was asked if that investigation was
  inconclusive before a raw API was selected;
- CLI commands are allowlisted and command arguments are structured;
- examples are runnable and tests are offline by default;
- `ctx_init()`, `schema("<namespace>")`, and `examples("<target>")` expose
  the intended public API.
