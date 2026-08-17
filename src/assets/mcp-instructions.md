# How to use {{server_name}} MCP

## Start here
- **CRITICAL** First call `ctx_init()` to learn available namespaces, contracts, and conventions.
- Use `schema("namespace")` for function details.
- Use `examples("namespace")` for runnable examples.

## Sessions
- Reuse the same `session_id` for dependent or stateful workflows.

## Parallel requests
- Run unrelated read-only requests in parallel only when each returns a small, limited result.
- In parallel, return only IDs, counts, statuses, or a small top-N summary. Do deeper reads afterward.
- Do not run broad or unbounded list, search, or helpers.collect() calls in parallel.
- Use a different session_id for each parallel branch. Reuse that ID for follow-up requests in the same branch.
- Same session_id = sequential requests. Different session_ids = requests may run in parallel.

## !!!Keep context SMALL!!!
*MANDATORY* With {{server_name}}, use the smallest correct Lua and return only what the AI needs for the next step.
Avoid verbose objects, extra fields, and unfiltered data. Prefer fewer, well-planned calls.
Fetch reusable data once, store it in {{server_name}} session memory, and reuse it instead of refetching or recomputing.
Keep temporary/full data in session memory; expose only compact summaries or essential fields.
If output size is uncertain, limit it before return.
