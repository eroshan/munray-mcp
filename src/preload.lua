local full_io, full_os, full_require = io, os, require
local raw_exec_mode = _raw.exec_mode
local raw_context_depth, raw_bootstrap, raw_direct_allowed = 0, true, false

function _install_raw_guards()
  local function guard(namespace, prefix)
    for name, value in pairs(namespace) do
      if type(value) == "function" then
        local original, operation = value, prefix .. "." .. name
        namespace[name] = function(...)
          if not raw_bootstrap and not raw_direct_allowed and raw_context_depth == 0 then
            return nil, {code="RAW_OUTSIDE_SCHEMA",message=operation .. " is internal; call a schema-backed public function",context={operation=operation},recoverable=false}
          end
          return original(...)
        end
      elseif type(value) == "table" then
        guard(value, prefix .. "." .. name)
      end
    end
  end
  guard(_raw, "_raw")
end

function _finish_raw_bootstrap(allow_direct)
  raw_direct_allowed = allow_direct == true
  raw_bootstrap = false
  _G._install_raw_guards = nil
  _G._finish_raw_bootstrap = nil
end

local function with_raw_context(fn, ...)
  raw_context_depth = raw_context_depth + 1
  local values = table.pack(pcall(fn, ...))
  raw_context_depth = raw_context_depth - 1
  if not values[1] then error(values[2], 0) end
  return table.unpack(values, 2, values.n)
end

local function with_service_stdlib(fn, ...)
  local previous_io, previous_os, previous_require = io, os, require
  io, os, require = full_io, full_os, full_require
  local values = table.pack(pcall(fn, ...))
  io, os, require = previous_io, previous_os, previous_require
  if not values[1] then error(values[2], 0) end
  return table.unpack(values, 2, values.n)
end

helpers = helpers or {}

local function helpers_empty_array()
  if type(json) == "table" and type(json._empty_array) == "function" then return json._empty_array() end
  return {}
end
local function helpers_mark_array(t)
  if type(json) == "table" and type(json._mark_array) == "function" then return json._mark_array(t) end
  local mt = getmetatable(t) or {}
  mt.__mcp_json_array = true
  return setmetatable(t, mt)
end
local function helpers_pack_tuple(...)
  return helpers_mark_array(table.pack(...))
end

function helpers.contains(values, expected)
  if type(values) ~= "table" then return false end
  for _, value in pairs(values) do if value == expected then return true end end
  return false
end

function helpers.collect(iterator, opts)
  if type(iterator) ~= "function" then return nil, { code = "INVALID_FIELD_VALUE", message = "helpers.collect: iterator must be a function", recoverable = false } end
  opts = opts or {}
  local limit = opts.limit
  if limit == 0 then return helpers_empty_array(), nil end
  local result = helpers_empty_array()
  local seen_count = 0
  while true do
    local packed = table.pack(pcall(iterator))
    local ok = packed[1]
    if not ok then
      return nil, { code = "ITERATOR_ERROR", message = "Iteration failed", context = {}, recoverable = false }
    end
    local tuple = helpers_pack_tuple(table.unpack(packed, 2, packed.n))
    if tuple[1] == nil then break end
    seen_count = seen_count + 1
    if not opts.filter or opts.filter(tuple, seen_count) then
      result[#result + 1] = opts.transform and opts.transform(tuple, seen_count) or tuple
    end
    if limit ~= nil and #result >= limit then break end
    local meta = tuple[2]
    if opts.max_pages and opts.max_pages > 0 and type(meta) == "table" and meta.page and meta.page > opts.max_pages then break end
  end
  return result, nil
end

function helpers.first(iterator)
  local packed = table.pack(pcall(iterator))
  if not packed[1] then return nil, { code = "ITERATOR_ERROR", message = "Iteration failed", context = {}, recoverable = false } end
  local tuple = helpers_pack_tuple(table.unpack(packed, 2, packed.n))
  if tuple[1] == nil then return nil, nil end
  return tuple, nil
end

function helpers.take(iterator, n)
  if type(n) == "number" and n == 0 then return helpers_empty_array(), nil end
  local items, err = helpers.collect(iterator, { limit = n })
  if err then return nil, err end
  if type(items) == "table" and next(items) == nil then return helpers_empty_array(), nil end
  return items, nil
end

function helpers.get_in(value, path, default)
  if type(path) == "string" then
    local parts = {}
    for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
    path = parts
  end
  for _, key in ipairs(path) do
    if type(value) ~= "table" then return default end
    value = value[key]
    if value == nil then return default end
  end
  return value
end

errutil = errutil or {}
local error_policies = {}
function errutil.register_policy(service, policy)
  if type(service) ~= "string" or service == "" or type(policy) ~= "table" then
    return nil, { code = "VALIDATION_FAILED", message = "invalid error policy", recoverable = false }
  end
  error_policies[service] = policy
  return true, nil
end
function errutil.for_service(service)
  return function(raw_error, meta)
    local policy = error_policies[service]
    local translated = policy and policy.classify and policy.classify(raw_error, meta) or nil
    if translated == nil and policy and policy.fallback then translated = policy.fallback(raw_error, meta) end
    if translated == nil then
      translated = { code = "UPSTREAM_ERROR", message = "Service request failed", recoverable = false }
    end
    translated.context = translated.context or {}
    return translated
  end
end

capabilities = capabilities or {}
local function namespace_at(path)
  local value = _G
  for part in path:gmatch("[^.]+") do
    if type(value) ~= "table" then return nil end
    value = value[part]
  end
  return value
end
function capabilities.schema(namespace)
  if type(namespace) ~= "string" or namespace:match("^__") then
    return nil, {code="NOT_FOUND",message="schema not found",recoverable=false}
  end
  local value = namespace_at(namespace)
  if type(value) ~= "table" or type(value.__schema) ~= "table" then
    return nil, {code="NOT_FOUND",message="schema not found",recoverable=false}
  end
  return value.__schema, nil
end
local function install_path(root, path, schema)
  local cursor = root
  local parts = {}
  for part in path:gmatch("[^.]+") do parts[#parts + 1] = part end
  for index, part in ipairs(parts) do
    if index == #parts then
      local view = {}
      for key, value in pairs(schema) do view[key] = value end
      for _, fn in ipairs(schema.functions or {}) do view[fn.name] = fn end
      cursor[part] = view
    else cursor[part] = cursor[part] or {}; cursor = cursor[part] end
  end
end

function _install_security_wrappers()
  local seen = {}
  local function metric_number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) or 0 end
    return 0
  end
  local function inc_metric(path, metric)
    if type(path) ~= "string" or path == "" then return end
    pcall(function()
      local key = "fn." .. path .. "." .. metric
      local current = _raw.store.get("metrics", key)
      _raw.store.put("metrics", key, metric_number(current) + 1)
    end)
  end
  local function visit(namespace)
    if type(namespace) ~= "table" or seen[namespace] then return end
    seen[namespace] = true
    local schema = namespace.__schema
    if type(schema) == "table" then
      for _, descriptor in ipairs(schema.functions or {}) do
        if type(namespace[descriptor.name]) == "function" and not descriptor.__mcp_server_wrapped then
          local original = namespace[descriptor.name]
          local metric_path = descriptor.path or ((schema.namespace or "") .. "." .. descriptor.name)
          local is_external = schema.service ~= nil and schema.service ~= "core"
          local is_iterator = descriptor.returns_contract == "core.iter"
          descriptor.__mcp_server_wrapped = true
          namespace[descriptor.name] = function(...)
            inc_metric(metric_path, "calls")
            if descriptor.mutating == true and raw_exec_mode() ~= "mutating" then
              inc_metric(metric_path, "blocked")
              return nil, { code = "MUTATING_BLOCKED", message = "Mutating operation blocked in read-only mode", context = { operation = descriptor.path or descriptor.name }, recoverable = false }
            end
            local function invoke(...)
              if is_external then return with_service_stdlib(original, ...) end
              return original(...)
            end
            local ok, values = pcall(function(...) return table.pack(with_raw_context(invoke, ...)) end, ...)
            if not ok then
              inc_metric(metric_path, "err")
              error(values, 0)
            end
            if (descriptor.returns_contract == "core.result" or descriptor.returns_contract == "core.async.result") and values.n >= 2 and values[2] ~= nil then
              inc_metric(metric_path, "err")
            end
            if is_iterator and type(values[1]) == "function" then
              local iterator = values[1]
              values[1] = function(...)
                local function step(...) return with_raw_context(iterator, ...) end
                if is_external then return with_service_stdlib(step, ...) end
                return step(...)
              end
            end
            return table.unpack(values, 1, values.n)
          end
        end
      end
    end
    for key, child in pairs(namespace) do if key ~= "__schema" and type(child) == "table" then visit(child) end end
  end
  for _, namespace in pairs(_G) do visit(namespace) end
end

vfs = vfs or {}
vfs.__schema = {
  namespace = "vfs", service = "core",
  functions = {
    { name = "mkdirp", mutating = false, returns_contract = "core.result" },
    { name = "write_text", mutating = false, returns_contract = "core.result" },
    { name = "read_text", mutating = false, returns_contract = "core.result" },
    { name = "ls", mutating = false, returns_contract = "core.result" },
    { name = "stat", mutating = false, returns_contract = "core.result" },
    { name = "to_txt", mutating = false, returns_contract = "core.result" },
    { name = "expose", mutating = true, returns_contract = "core.result" },
  },
}
function vfs.mkdirp(path) return _raw.vfs.mkdirp(path) end
function vfs.ensure_parent(path) local parent = path:match("^(.+)/[^/]+$"); if not parent then return true, nil end; return vfs.mkdirp(parent) end
function vfs.write_text(path, text, opts) return _raw.vfs.write_text(path, text, opts) end
function vfs.read_text(path, opts) return _raw.vfs.read_text(path, opts) end
function vfs.ls(path, opts) return _raw.vfs.list(path, opts) end
function vfs.stat(path) return _raw.vfs.stat(path) end
function vfs.expose(paths) return _raw.vfs.expose(paths) end
function vfs.to_txt(path, opts) return _raw.vfs.to_text(path, opts) end

async_task = async_task or {}
async_task.__schema = {
  namespace = "async_task", service = "core",
  functions = {
    { name = "status", mutating = false, returns_contract = "core.result" },
    { name = "result", mutating = false, returns_contract = "core.result" },
    { name = "wait", mutating = false, returns_contract = "core.result" },
    { name = "cancel", mutating = false, returns_contract = "core.result" },
  },
}
function async_task.status(task_id) if not task_id then return nil, {code="VALIDATION",message="task_id is required",recoverable=false} end; return _raw.task.status(task_id) end
function async_task.result(task_id, _) if not task_id then return nil, {code="VALIDATION",message="task_id is required",recoverable=false} end; return _raw.task.result(task_id) end
function async_task.wait(task_id, timeout_ms) if not task_id then return nil, {code="VALIDATION",message="task_id is required",recoverable=false} end; return _raw.task.wait(task_id, timeout_ms or 295000) end
function async_task.cancel(task_id) if not task_id then return nil, {code="VALIDATION",message="task_id is required",recoverable=false} end; return _raw.task.cancel(task_id) end

ingest = ingest or {}
ingest.__schema = { namespace = "ingest", service = "core", functions = { { name = "get", mutating = false, returns_contract = "core.result" } } }
function ingest.get(token) return _raw.ingest.get(token) end

store = store or {}
store.__schema = {
  namespace = "store", service = "core",
  functions = {
    {name="put",mutating=true,returns_contract="core.result"},
    {name="get",mutating=false,returns_contract="core.result"},
    {name="delete",mutating=true,returns_contract="core.result"},
    {name="keys",mutating=false,returns_contract="core.result"},
    {name="len",mutating=false,returns_contract="core.result"},
    {name="clear",mutating=true,returns_contract="core.result"},
    {name="cache_get",mutating=false,returns_contract="core.result"},
    {name="cache_set",mutating=true,returns_contract="core.result"},
    {name="save_snippet",mutating=true,returns_contract="core.result"},
  },
}
local dynamic_snippets = {}
local function snippet_namespace(path, create)
  local parts = {}
  for part in tostring(path):gmatch("[^.]+") do parts[#parts+1] = part end
  if #parts < 2 then return nil, nil, {code="VALIDATION",message="path must include namespace and function",recoverable=false} end
  local current = _G
  for index = 1, #parts - 1 do
    local part = parts[index]
    if current[part] == nil and create then current[part] = {} end
    if type(current[part]) ~= "table" then return nil, nil, {code="VALIDATION",message="namespace segment is not a table",recoverable=false} end
    current = current[part]
    if create and current.__schema == nil then
      current.__schema = {namespace=table.concat(parts, ".", 1, index),service=parts[1],functions={}}
    end
  end
  return current, parts[#parts], nil
end
local function snippet_descriptor(namespace, name, path)
  for index, descriptor in ipairs(namespace.__schema.functions or {}) do
    if descriptor.name == name or descriptor.path == path then return descriptor, index end
  end
  return nil, nil
end
function store.put(kind, key, value, opts)
  opts = opts or {}
  if kind == "fn" then
    local namespace, name, path_err = snippet_namespace(key, true)
    if path_err then return nil, path_err end
    if namespace[name] ~= nil then return nil, {code="ALREADY_EXISTS",message=key.." already exists",context={path=key},recoverable=false} end
    local chunk, compile_err = load("return " .. tostring(value), "=local_store.fn:" .. key, "t", _G)
    if not chunk then return nil, {code="VALIDATION",message=compile_err,recoverable=false} end
    local ok, fn = pcall(chunk)
    if not ok or type(fn) ~= "function" then return nil, {code="VALIDATION",message=tostring(fn),recoverable=false} end
    local stored, raw_err = _raw.store.put(kind, key, value, opts)
    if raw_err then return nil, raw_err end
    namespace[name] = fn
    local descriptor = {
      name=name,
      path=key,
      signature="(...)",
      description=opts.description or "Stored function",
      mutating=false,
      returns_contract="core.result",
      returns_typed={
        {name="result",type="any"},
        {name="err",type="Error|nil"},
      },
      origin="local_store",
    }
    namespace.__schema.functions[#namespace.__schema.functions+1] = descriptor
    dynamic_snippets[key] = {namespace=namespace,name=name,descriptor=descriptor}
    _install_security_wrappers()
    return stored, nil
  elseif kind == "schema" then
    local stored, raw_err = _raw.store.put(kind, key, value, opts)
    if raw_err then return nil, raw_err end
    local entry = dynamic_snippets[key]
    if entry then
      local chunk, compile_err = load("return " .. tostring(value), "=local_store.schema:" .. key, "t", _G)
      if not chunk then return nil, {code="VALIDATION",message=compile_err,recoverable=false} end
      local ok, schema = pcall(chunk)
      if not ok or type(schema) ~= "table" then return nil, {code="VALIDATION",message=tostring(schema),recoverable=false} end
      for field in pairs(entry.descriptor) do entry.descriptor[field] = nil end
      for field, field_value in pairs(schema) do entry.descriptor[field] = field_value end
      entry.descriptor.name = entry.name
      entry.descriptor.path = key
      if entry.descriptor.signature == nil then entry.descriptor.signature = "(...)" end
      if entry.descriptor.returns_contract == nil then entry.descriptor.returns_contract = "core.result" end
      if entry.descriptor.mutating == nil then entry.descriptor.mutating = false end
      if entry.descriptor.description == nil then entry.descriptor.description = "Stored function" end
      if entry.descriptor.returns_typed == nil then
        entry.descriptor.returns_typed = {
          {name="result",type="any"},
          {name="err",type="Error|nil"},
        }
      end
      entry.descriptor.origin = "local_store"
      _install_security_wrappers()
    end
    return stored, nil
  elseif kind == "example" then
    local stored, raw_err = _raw.store.put(kind, key, value, opts)
    if raw_err then return nil, raw_err end
    local entry = dynamic_snippets[key]
    if entry then
      local chunk = load("return " .. tostring(value), "=local_store.example:" .. key, "t", _G)
      local ok, example = false, nil
      if chunk then ok, example = pcall(chunk) end
      if ok and type(example) == "string" then entry.descriptor.examples = example end
    end
    return stored, nil
  end
  return _raw.store.put(kind, key, value, opts)
end
function store.get(kind, key) return _raw.store.get(kind, key) end
function store.delete(kind, key)
  local deleted, err = _raw.store.delete(kind, key)
  if err then return nil, err end
  if deleted and kind == "fn" and dynamic_snippets[key] then
    local entry = dynamic_snippets[key]
    entry.namespace[entry.name] = nil
    local _, index = snippet_descriptor(entry.namespace, entry.name, key)
    if index then table.remove(entry.namespace.__schema.functions, index) end
    dynamic_snippets[key] = nil
  end
  return deleted, nil
end
function store.keys(kind) return _raw.store.keys(kind) end
function store.len(kind) return _raw.store.len(kind) end
function store.clear(kind) return _raw.store.clear(kind) end
function store.cache_get(...) return _raw.store.cache_get(...) end
function store.cache_set(...) return _raw.store.cache_set(...) end
function store.save_snippet(a, b, c)
  local path, code, opts
  if type(a) == "table" and b == nil then path, code, opts = a.path, a.code, a else path, code, opts = a, b, c or {} end
  if type(path) ~= "string" or path == "" then return nil, {code="VALIDATION",message="path is required",recoverable=false} end
  if type(code) ~= "string" or code == "" then return nil, {code="VALIDATION",message="code must be a non-empty Lua function literal",recoverable=false} end
  local ok, err = store.put("fn", path, code, {content_type="lua",description=opts.description})
  if err then return nil, err end
  local entry = dynamic_snippets[path]
  if opts.schema_expr then
    ok, err = store.put("schema", path, opts.schema_expr, {content_type="lua"})
    if err then return nil, err end
  elseif entry then
    entry.descriptor.description = opts.description or entry.descriptor.description
    entry.descriptor.params = opts.params
    entry.descriptor.returns_typed = opts.returns
  end
  if opts.example then
    ok, err = store.put("example", path, string.format("%q", opts.example), {content_type="lua"})
    if err then return nil, err end
  end
  return true, nil
end
local function discover_schemas()
  local result, seen = {}, {}
  local function visit(value)
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    if type(value.__schema) == "table" and type(value.__schema.namespace) == "string" and not value.__schema.namespace:match("^__") then
      install_path(result, value.__schema.namespace, value.__schema)
    end
    for key, child in pairs(value) do
      if key ~= "__schema" and type(child) == "table" then visit(child) end
    end
  end
  for _, value in pairs(_G) do visit(value) end
  return result
end
function capabilities.schemas(_) return discover_schemas() end
function capabilities.examples(key)
  if type(key) == "string" then
    local parts = {}
    for part in key:gmatch("[^.]+") do parts[#parts+1] = part end
    for split = #parts - 1, 1, -1 do
      local namespace, method = table.concat(parts, ".", 1, split), parts[split + 1]
      local schema = capabilities.schema(namespace)
      if schema then
        for _, descriptor in ipairs(schema.functions or {}) do
          if descriptor.name == method and type(descriptor.examples) == "string" then return descriptor.examples end
        end
      end
    end
  end
  if type(_examples) ~= "table" then return nil end
  if _examples[key] then return _examples[key] end
  return _examples[key:match("^[^.]+")]
end
function capabilities.invalidate() return true, nil end
function capabilities.ai_context()
  local context = {
    contracts = {
      ["core.result"] = "Returns (result, err)",
      ["core.iter"] = "Generic-for iterator yielding (item, meta)",
      ["core.error"] = "{code,message,context,hint?,recoverable}",
    },
    conventions = { "Global variables persist for the session; locals are call-scoped." },
    iter_helpers = { "collect", "first", "take", "get_in" },
    discovery = { target_format = { pattern = "<service> | <service>.<resource>" } },
    hints = {
      global = {
        "Use capabilities.schema(target) before calling an unfamiliar namespace.",
        "VFS is runtime-local scratch storage, not the host filesystem.",
      },
    },
    namespaces = {},
    runtime = {},
  }
  local runtime = rawget(_G, "__runtime")
  if type(runtime) == "table" and type(runtime.server_id) == "string" and runtime.server_id ~= "" then
    context.runtime.server_id = runtime.server_id
  end
  local function summarize(node, target)
    for key, value in pairs(node) do
      if type(value) == "table" and value.functions then
        local summary = {}
        for _, fn in ipairs(value.functions or {}) do summary[fn.name] = fn.description or fn.signature or "operation" end
        target[key] = summary
        for child_key, child in pairs(value) do
          if type(child) == "table" and child.namespace and child.functions then
            summarize({ [child_key] = child }, target[key])
          end
        end
      elseif type(value) == "table" then
        target[key] = {}; summarize(value, target[key])
      end
    end
  end
  summarize(discover_schemas(), context.namespaces)
  return context
end

test = test or {}
local test_passed, test_failed, current_test = 0, 0, nil
function test.describe(name) current_test = name; print("\n=== " .. name .. " ===") end
function test.assert(condition, message)
  if condition then
    test_passed = test_passed + 1
    print("  ✓ " .. (message or "assertion passed"))
  else
    test_failed = test_failed + 1
    print("  ✗ " .. (message or "assertion failed"))
  end
end
function test.assert_eq(actual, expected, message) test.assert(actual == expected, message or ("expected " .. tostring(expected) .. ", got " .. tostring(actual))) end
function test.assert_not_nil(value, message) test.assert(value ~= nil, message or "expected non-nil value") end
function test.assert_nil(value, message) test.assert(value == nil, message or ("expected nil, got " .. tostring(value))) end
function test.assert_error(fn, message) local ok = pcall(fn); test.assert(not ok, message or "expected error") end
function test.assert_no_error(fn, message) local ok, err = pcall(fn); test.assert(ok, message or ("expected no error, got " .. tostring(err))) end
function test.summary()
  print(string.format("Tests: %d passed, %d failed, %d total", test_passed, test_failed, test_passed + test_failed))
  if test_failed > 0 then error(string.format("%d Lua test assertion(s) failed", test_failed)) end
end
function test.reset() test_passed, test_failed, current_test = 0, 0, nil end
