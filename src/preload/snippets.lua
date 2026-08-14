-- Core-owned saved snippets. Persistence is provided by _raw.snippets; this
-- layer only compiles and installs the saved Lua function in the live runtime.
snippets = {}
local dynamic = {}

local function fail(code, message, context)
  return nil, {code=code, message=message, context=context or {}, recoverable=false}
end

local function namespace_for(path, create)
  local parts = {}
  for part in tostring(path):gmatch("[^.]+") do parts[#parts + 1] = part end
  if #parts < 2 then return fail("VALIDATION", "path must include namespace and function") end
  local namespace = _G
  for i = 1, #parts - 1 do
    local part = parts[i]
    if namespace[part] == nil and create then namespace[part] = {} end
    if type(namespace[part]) ~= "table" then return fail("VALIDATION", "namespace segment is not a table") end
    namespace = namespace[part]
    if create and namespace.__schema == nil then
      namespace.__schema = {namespace=table.concat(parts, ".", 1, i), service=parts[1], functions={}}
    end
  end
  return namespace, parts[#parts]
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
  if type(definition) ~= "table" or type(definition.path) ~= "string" or definition.path == "" then return fail("VALIDATION", "path is required") end
  if type(definition.code) ~= "string" or definition.code == "" then return fail("VALIDATION", "code is required") end
  local namespace, name, err = namespace_for(definition.path, true)
  if err then return nil, name end
  if namespace[name] ~= nil and not replacing then return fail("ALREADY_EXISTS", definition.path .. " already exists", {path=definition.path}) end
  local chunk, compile_err = load("return " .. definition.code, "=snippet:" .. definition.path, "t", _G)
  if not chunk then return fail("VALIDATION", compile_err) end
  local ok, fn = pcall(chunk)
  if not ok or type(fn) ~= "function" then return fail("VALIDATION", tostring(fn)) end
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
  return true, nil
end

function snippets.save(definition)
  -- A saved snippet may replace its own prior definition, but may never take
  -- over a function supplied by the core or a service pack.
  local ok, err = install(definition, dynamic[definition.path] ~= nil)
  if not ok then return nil, err end
  local persisted, persist_err = _raw.snippets.save(definition)
  if persist_err then
    local entry = dynamic[definition.path]
    entry.namespace[entry.name] = nil
    for index, value in ipairs(entry.namespace.__schema.functions) do
      if value == entry.descriptor then table.remove(entry.namespace.__schema.functions, index); break end
    end
    dynamic[definition.path] = nil
    return nil, persist_err
  end
  return persisted, nil
end

function snippets.delete(path)
  local entry = dynamic[path]
  local deleted, err = _raw.snippets.delete(path)
  if err then return nil, err end
  if deleted and entry then
    entry.namespace[entry.name] = nil
    for index, value in ipairs(entry.namespace.__schema.functions) do
      if value == entry.descriptor then table.remove(entry.namespace.__schema.functions, index); break end
    end
    dynamic[path] = nil
  end
  return deleted, nil
end

function snippets.get(path) return _raw.snippets.get(path) end
function snippets.list() return _raw.snippets.list() end
-- Called only while constructing a trusted runtime. It does not rewrite the DB.
function __restore_snippet(definition) return install(definition, false) end

local function descriptor_for(name, mutating, signature, description)
  return {name=name,path="snippets."..name,mutating=mutating,signature=signature,returns_contract="core.result",description=description,returns_typed={{name="result",type="any"},{name="err",type="core.error|nil"}}}
end
snippets.__schema = {namespace="snippets",service="core",functions={
  descriptor_for("save", true, "(definition)", "Save and immediately register a trusted snippet"),
  descriptor_for("delete", true, "(path)", "Delete a snippet from this runtime and persistence"),
  descriptor_for("get", false, "(path)", "Get a stored snippet definition"),
  descriptor_for("list", false, "()", "List stored snippet definitions"),
}}
