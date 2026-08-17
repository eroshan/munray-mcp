-- {{SERVICE}} bootstrap contract test
-- Update the starter-operation assertions after replacing NOT_IMPLEMENTED.

local info, init_err = ctx_init()
assert(info ~= nil, init_err and init_err.message or "ctx_init failed")

local definition, schema_err = schema("{{SERVICE}}.resource")
assert(definition ~= nil, schema_err and schema_err.message or "resource schema was not discovered")
assert(definition.functions ~= nil, "resource functions were not discovered")
local has_get = false
for _, function_definition in ipairs(definition.functions) do
  if function_definition.name == "get" then
    has_get = true
    break
  end
end
assert(has_get, "starter get function metadata is missing")

local result, err = {{SERVICE}}.resource.get("example-id")
assert(result == nil, "starter operation must not claim a successful integration")
assert(type(err) == "table" and err.code == "NOT_IMPLEMENTED", "starter operation must return NOT_IMPLEMENTED")
