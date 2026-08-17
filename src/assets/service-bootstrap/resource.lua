-- {{SERVICE}}.resource operations
--
-- This is a deliberately safe starting point. Replace the NOT_IMPLEMENTED
-- result with a real read-only transport wrapper. Capture each raw primitive
-- in a local upvalue in this file (for example, the HTTP request primitive)
-- instead of exposing it on the public namespace. Use sys.secrets and sys.auth
-- references for credentials; never read, return, or print credential values.

local function validation_error(message, context)
  return {
    code = "VALIDATION_FAILED",
    message = message,
    context = context or {},
    recoverable = false,
    suggestion = "Check the parameter values and retry.",
  }
end

local function not_implemented(operation)
  return {
    code = "NOT_IMPLEMENTED",
    message = operation .. " has not been implemented yet.",
    recoverable = false,
    suggestion = "Implement the service transport wrapper before using this operation.",
  }
end

-- Replace this with an explicit, stateless read operation. Return plain Lua
-- values as (result, nil) on success or (nil, structured_error) on failure.
function {{SERVICE}}.resource.get(id)
  if type(id) ~= "string" or id == "" then
    return nil, validation_error("id must be a non-empty string", { field = "id" })
  end
  return nil, not_implemented("{{SERVICE}}.resource.get")
end

-- Mark every mutation guarded=true here. Do not implement permission checks in
-- Lua and do not infer mutation policy from an HTTP method or CLI arguments:
-- the schema is the sole policy declaration. List operations return generic-for
-- iterators and use returns_contract="core.iter" rather than materialized lists.
{{SERVICE}}.resource.__schema = {
  namespace = "{{SERVICE}}.resource",
  service = "{{SERVICE}}",
  summary = "<Resource> operations.",
  functions = {
    {
      name = "get",
      signature = "(id)",
      description = "Fetch one <Resource> by id.",
      guarded = false,
      returns_contract = "core.result",
      params = {
        { name = "id", type = "string", optional = false },
      },
      returns_typed = {
        { name = "result", type = "Resource" },
        { name = "err", type = "core.error|nil" },
      },
      examples = [[
local resource, err = {{SERVICE}}.resource.get("example-id")
if err then error(err.message or tostring(err)) end
return resource
]],
    },
  },
  types = {
    Resource = { shape = "{id:string, ...}" },
  },
}
