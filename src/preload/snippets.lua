-- Core-owned saved snippets. Persistence is provided by _raw.snippets; this
-- layer compiles and installs saved Lua functions in the live runtime.
snippets = {}
local dynamic = {}
-- Namespace tables and schemas created by snippets are removed once their last
-- dynamic function/child namespace is gone. Never prune service-owned tables.
local snippet_namespaces = {}

local function fail(code, message, context)
  return nil, {code=code, message=message, context=context or {}, recoverable=false}
end

-- The public API uses a Lua namespace plus a function name. `path` remains an
-- internal persistence key and a legacy input for already-saved definitions.
local function normalize_definition(definition)
  if type(definition) ~= "table" then return fail("VALIDATION", "definition must be a table") end
  local namespace, name = definition.namespace, definition.name
  if (namespace == nil or name == nil) and type(definition.path) == "string" then
    namespace, name = definition.path:match("^(.*)%.([^.]+)$")
  end
  if type(namespace) ~= "string" or namespace == "" or type(name) ~= "string" or name == "" then
    return fail("VALIDATION", "namespace and name are required")
  end
  if namespace:find("/", 1, true) or name:find("/", 1, true) then
    return fail("VALIDATION", "namespace and name use Lua dots, not filesystem slashes")
  end
  local path = namespace .. "." .. name
  local normalized = {}
  for key, value in pairs(definition) do normalized[key] = value end
  normalized.namespace, normalized.name, normalized.path = namespace, name, path
  return normalized
end

local function namespace_for(path, create)
  local parts = {}
  for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
  if #parts < 2 then return fail("VALIDATION", "namespace must include at least one namespace segment and a function name") end
  local namespace = _G
  for i = 1, #parts - 1 do
    local part = parts[i]
    if namespace[part] == nil and create then namespace[part] = {} end
    if type(namespace[part]) ~= "table" then return fail("VALIDATION", "namespace segment is not a table") end
    namespace = namespace[part]
    if create and namespace.__schema == nil then
      local full_namespace = table.concat(parts, ".", 1, i)
      namespace.__schema = {namespace=full_namespace, service=parts[1], functions={}}
      snippet_namespaces[full_namespace] = true
    end
  end
  return namespace, parts[#parts]
end

-- Accept a function expression, a chunk returning a function, or an ordinary
-- named Lua function declaration. The latter is useful when pasting normal Lua.
local function compile_function(definition)
  local expression, expression_err = load("return " .. definition.code, "=snippet:" .. definition.path, "t", _G)
  if expression then
    local ok, fn = pcall(expression)
    if ok and type(fn) == "function" then return fn end
  end
  local chunk, chunk_err = load(definition.code, "=snippet:" .. definition.path, "t", _G)
  if not chunk then return fail("VALIDATION", chunk_err or expression_err) end
  local ok, value = pcall(chunk)
  if not ok then return fail("VALIDATION", tostring(value)) end
  if type(value) == "function" then return value end
  -- `function fibonacci(...) ... end` assigns the declared function globally.
  -- Move the matching bare declaration into its requested namespace and remove
  -- that temporary global so the snippet has no accidental public alias.
  local declared = _G[definition.name]
  if type(declared) == "function" then
    _G[definition.name] = nil
    return declared
  end
  return fail("VALIDATION", "code must evaluate to a function, return a function, or declare function " .. definition.name .. "(...)")
end

local function descriptor(definition, name)
  local descriptor = {
    name=name, path=definition.path, signature="(...)", description=definition.description or "Stored function",
    mutating=false, returns_contract="core.result",
    returns_typed={{name="result",type="any"},{name="err",type="core.error|nil"}}, origin="snippet",
  }
  if definition.schema_expr then
    local chunk, err = load("return " .. definition.schema_expr, "=snippet-schema:" .. definition.path, "t", _G)
    if not chunk then return fail("VALIDATION", err) end
    local ok, values = pcall(chunk)
    if not ok or type(values) ~= "table" then return fail("VALIDATION", tostring(values)) end
    for key, value in pairs(values) do descriptor[key] = value end
  end
  descriptor.name, descriptor.path = name, definition.path
  descriptor.signature = descriptor.signature or "(...)"
  descriptor.description = descriptor.description or "Stored function"
  descriptor.mutating = descriptor.mutating or false
  descriptor.returns_contract = descriptor.returns_contract or "core.result"
  if definition.example then descriptor.examples = definition.example end
  if definition.params then descriptor.params = definition.params end
  if definition.returns then descriptor.returns_typed = definition.returns end
  return descriptor
end

local function install(definition, replacing)
  local normalized, normalize_err = normalize_definition(definition)
  if not normalized then return nil, normalize_err end
  definition = normalized
  if type(definition.code) ~= "string" or definition.code == "" then return fail("VALIDATION", "code is required") end
  local namespace, name, err = namespace_for(definition.path, true)
  if err then return nil, name end
  if namespace[name] ~= nil and not replacing then return fail("ALREADY_EXISTS", definition.path .. " already exists", {namespace=definition.namespace, name=name}) end
  local fn, compile_err = compile_function(definition)
  if not fn then return nil, compile_err end
  local schema, schema_err = descriptor(definition, name)
  if not schema then return nil, schema_err end
  namespace[name] = fn
  local old = dynamic[definition.path]
  if old then
    for index, value in ipairs(namespace.__schema.functions) do
      if value == old.descriptor then table.remove(namespace.__schema.functions, index); break end
    end
  end
  namespace.__schema.functions[#namespace.__schema.functions + 1] = schema
  dynamic[definition.path] = {namespace=namespace, name=name, descriptor=schema}
  return definition, nil
end

function snippets.save(definition)
  local definition_err
  definition, definition_err = normalize_definition(definition)
  if not definition then return nil, definition_err end
  local normalized, err = install(definition, dynamic[definition.path] ~= nil)
  if not normalized then return nil, err end
  local persisted, persist_err = _raw.snippets.save(normalized)
  if persist_err then
    local entry = dynamic[normalized.path]
    entry.namespace[entry.name] = nil
    for index, value in ipairs(entry.namespace.__schema.functions) do
      if value == entry.descriptor then table.remove(entry.namespace.__schema.functions, index); break end
    end
    dynamic[normalized.path] = nil
    return nil, persist_err
  end
  capabilities.invalidate()
  return persisted, nil
end

local function prune_empty_namespaces(path)
  local parts = {}
  for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
  for depth = #parts - 1, 1, -1 do
    local full_namespace = table.concat(parts, ".", 1, depth)
    if not snippet_namespaces[full_namespace] then break end
    local parent = _G
    for index = 1, depth - 1 do parent = parent[parts[index]] end
    local namespace = parent[parts[depth]]
    local empty = #namespace.__schema.functions == 0
    if empty then
      for key, _ in pairs(namespace) do
        if key ~= "__schema" then empty = false; break end
      end
    end
    if not empty then break end
    parent[parts[depth]] = nil
    snippet_namespaces[full_namespace] = nil
  end
end

local function snippet_path(namespace, name)
  if name == nil then return namespace end -- legacy fully-qualified path
  return namespace .. "." .. name
end

function snippets.delete(namespace, name)
  local path = snippet_path(namespace, name)
  local entry = dynamic[path]
  local deleted, err = _raw.snippets.delete(path)
  if err then return nil, err end
  if deleted and entry then
    entry.namespace[entry.name] = nil
    for index, value in ipairs(entry.namespace.__schema.functions) do
      if value == entry.descriptor then table.remove(entry.namespace.__schema.functions, index); break end
    end
    dynamic[path] = nil
    prune_empty_namespaces(path)
  end
  if deleted then capabilities.invalidate() end
  return deleted, nil
end

local function public_definition(definition)
  if not definition then return nil end
  local namespace, name = definition.path:match("^(.*)%.([^.]+)$")
  definition.namespace, definition.name, definition.path = namespace, name, nil
  return definition
end

function snippets.get(namespace, name)
  local definition, err = _raw.snippets.get(snippet_path(namespace, name))
  return public_definition(definition), err
end
function snippets.list()
  local definitions, err = _raw.snippets.list()
  if definitions then for _, definition in ipairs(definitions) do public_definition(definition) end end
  return definitions, err
end
function __restore_snippet(definition) return install(definition, false) end

local function descriptor_for(name, mutating, signature, description, examples)
  return {name=name,path="snippets."..name,mutating=mutating,signature=signature,returns_contract="core.result",description=description,examples=examples,returns_typed={{name="result",type="any"},{name="err",type="core.error|nil"}}}
end
snippets.__schema = {namespace="snippets",service="core",examples=[=[
local ok, err = snippets.save({
  namespace = "math", name = "fibonacci",
  code = [[function fibonacci(n)
    if n < 2 then return n end
    return math.fibonacci(n - 1) + math.fibonacci(n - 2)
  end]],
  description = "Return the nth Fibonacci number",
})
if err then error(err.message) end
return math.fibonacci(10)
]=],functions={
  descriptor_for("save", true, "({namespace:string, name:string, code:string, ...})", "Persist and immediately register a trusted Lua function at namespace.name. code may be a function expression, a chunk that returns a function, or a named function declaration.", nil),
  descriptor_for("delete", true, "(namespace, name)", "Delete a stored function from this runtime and persistence", nil),
  descriptor_for("get", false, "(namespace, name)", "Get a stored function definition", nil),
  descriptor_for("list", false, "()", "List stored function definitions", nil),
}}
