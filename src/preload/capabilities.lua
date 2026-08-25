-- preload/capabilities.lua
-- Lua-owned introspection built from Lua `__schema` tables.

-- Contract naming policy:
-- - Schemas use unversioned names: core.iter, core.result, core.error
local ITER_CONTRACT = {
	kind = "iterator",
	loop = "for-in",
	step = "(state, control) -> (item, meta)",
	end_ = "item == nil",
	errors = "throws",
	consumer = "pcall",
	description = "Iterator; consume via for ... in ... or helpers.collect(iterator, {limit=N}) / helpers.take(iterator, N)",
	pattern = "items, err = helpers.collect(iterator, {limit = 10})",
	example = "items, err = helpers.collect(some.ns.list(opts), {limit = 10})",
}

local ERROR_CONTRACT = {
	kind = "error",
	shape = "{code:string, message:string, recoverable?:boolean, context?:table}",
}

local RESULT_CONTRACT = {
	kind = "result",
	ok = "(result, nil)",
	err = "(nil, Error)",
	error_type = "core.error",
	hint = "Use examples(<namespace>) for runnable usage",
	description = "(val, err). Always check err first.",
	pattern = "val, err = fn(...)" ,
	example = "value, err = some.ns.get(id)",
}

local ASYNC_RESULT_CONTRACT = {
	kind = "async.result",
	ok = "(task_id, nil)",
	err = "(nil, Error)",
	handle = "task_id",
	next = "async_task.wait/result(task_id) -> (result, err)",
	description = "Async start call: (task_id, err). Later: async_task.wait/result(task_id) -> (result, err).",
	pattern = "task_id, err = fn(...); if err then ... end; result, err = async_task.wait(task_id)",
	example = "task_id, err = some.ns.expensive_op(opts)",
}

local _CORE_CONTRACTS = {
	["core.iter"] = ITER_CONTRACT,
	["core.error"] = ERROR_CONTRACT,
	["core.result"] = RESULT_CONTRACT,
	["core.async.result"] = ASYNC_RESULT_CONTRACT,
}

-- Ensure core namespaces have at least minimal schemas.
-- These tables are created by Go before preload runs.


if type(json) == "table" and json.__schema == nil then
	json.__schema = {
		namespace = "json",
		service = "json",
		functions = {
			{
				name = "encode",
				signature = "(value, [pretty])",
				returns_contract = "core.result",
				guarded = false,
				description = "Convert Lua value to JSON string",
				params = { { name = "value", type = "any" }, { name = "pretty", type = "boolean", optional = true } },
				returns_typed = { { name = "result", type = "string" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "decode",
				signature = "(json_string)",
				returns_contract = "core.result",
				guarded = false,
				description = "Parse JSON string to Lua value",
				params = { { name = "json_string", type = "string" } },
				returns_typed = { { name = "result", type = "any" }, { name = "err", type = "core.error|nil" } },
			},
		},
	}
end

local yaml_ns = rawget(_G, "yaml")
if type(yaml_ns) == "table" and yaml_ns.__schema == nil then
	yaml_ns.__schema = {
		namespace = "yaml",
		service = "yaml",
		functions = {
			{
				name = "encode",
				signature = "(value, [pretty])",
				returns_contract = "core.result",
				guarded = false,
				description = "Convert Lua value to YAML string",
				params = { { name = "value", type = "any" }, { name = "pretty", type = "boolean", optional = true } },
				returns_typed = { { name = "result", type = "string" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "decode",
				signature = "(yaml_string)",
				returns_contract = "core.result",
				guarded = false,
				description = "Parse YAML string to Lua value",
				params = { { name = "yaml_string", type = "string" } },
				returns_typed = { { name = "result", type = "any" }, { name = "err", type = "core.error|nil" } },
			},
		},
	}
end

local _discovered = nil
local _warnings = {}

local os_getenv = nil
if type(os) == "table" and type(os.getenv) == "function" then
	local getenv_fn = os.getenv
	os_getenv = function(key)
		return getenv_fn(key)
	end
end

-- Dynamic snippet installation calls this trusted internal hook before the
-- next discovery request. It is intentionally not a public Lua API.
function _invalidate_capabilities()
	_discovered = nil
	_warnings = {}
end

local stderr_write = nil
if type(io) == "table" and type(io.stderr) == "userdata" and type(io.stderr.write) == "function" then
	local stderr = io.stderr
	stderr_write = function(message)
		stderr:write(message)
	end
end

local function warn(msg)
	if type(msg) ~= "string" then
		return
	end
	if stderr_write ~= nil then
		stderr_write("Warning: " .. msg .. "\n")
	end
	table.insert(_warnings, msg)
end

local function error_table(code, message)
	return { code = code, message = message, recoverable = true }
end

local function is_top_level_namespace(ns)
	return type(ns) == "string" and ns ~= "" and ns:find(".", 1, true) == nil
end

-- Rust provides the checked-in JSON Schema during bootstrap. Keep the
-- discovery validator's required and additional-property rules sourced from it
-- so the public contract cannot silently diverge from this Lua implementation.
local CAPABILITY_SCHEMA = rawget(_G, "__capabilities_schema")
local function schema_definition(name)
	if type(CAPABILITY_SCHEMA) ~= "table" then return nil end
	if name == nil then return CAPABILITY_SCHEMA end
	return type(CAPABILITY_SCHEMA["$defs"]) == "table" and CAPABILITY_SCHEMA["$defs"][name] or nil
end

local function validate_declared_fields(value, definition, path)
	if type(definition) ~= "table" then return false, "internal capabilities schema is unavailable" end
	for _, key in ipairs(definition.required or {}) do
		if value[key] == nil then return false, "missing required field: " .. path .. key end
	end
	local properties = definition.properties
	if definition.additionalProperties == false and type(properties) == "table" then
		for key, _ in pairs(value) do
			if properties[key] == nil then return false, "unknown property: " .. path .. key end
		end
	end
	return true, nil
end

local function validate_schema(s)
	if type(s) ~= "table" then
		return false, "__schema must be a table"
	end
	local ok, declared_err = validate_declared_fields(s, schema_definition(nil), "__schema.")
	if not ok then return false, declared_err end
	if type(s.namespace) ~= "string" or s.namespace == "" then
		return false, "__schema.namespace must be a non-empty string"
	end
	if type(s.service) ~= "string" or s.service == "" then
		return false, "__schema.service must be a non-empty string"
	end
	if type(s.functions) ~= "table" then
		return false, "__schema.functions must be an array"
	end
	if s.usage_hint ~= nil then
		if type(s.usage_hint) ~= "string" then
			return false, "__schema.usage_hint must be a string"
		end
		if not is_top_level_namespace(s.namespace) then
			return false, "__schema.usage_hint is allowed only on top-level namespaces"
		end
	end

	for i, fn in ipairs(s.functions) do
		if type(fn) ~= "table" then
			return false, "__schema.functions[" .. i .. "] must be a table"
		end

		local ok, declared_err = validate_declared_fields(fn, schema_definition("FunctionSchema"), "functions[" .. i .. "].")
		if not ok then return false, declared_err end

		if type(fn.name) ~= "string" or fn.name == "" then
			return false, "functions[" .. i .. "].name must be a non-empty string"
		end
		if type(fn.signature) ~= "string" then
			return false, "functions[" .. i .. "].signature must be a string"
		end
		if fn.signature == "" or fn.signature:sub(1, 1) ~= "(" then
			return false, "functions[" .. i .. "].signature must start with '(' (arglist-only, e.g. '(id, opts?)')"
		end
		if type(fn.returns_contract) ~= "string" or fn.returns_contract == "" then
			return false, "functions[" .. i .. "].returns_contract must be a non-empty string"
		end
		if type(fn.description) ~= "string" then
			return false, "functions[" .. i .. "].description must be a string"
		end
		if type(fn.guarded) ~= "boolean" then
			return false, "functions[" .. i .. "].guarded must be boolean"
		end

		if fn.params ~= nil and type(fn.params) ~= "table" then
			return false, "functions[" .. i .. "].params must be an array"
		end
		if type(fn.returns_typed) ~= "table" then
			return false, "functions[" .. i .. "].returns_typed must be an array"
		end
		if fn.returns_contract == "core.iter" then
			if type(fn.yields) ~= "string" or fn.yields == "" then
				return false, "functions[" .. i .. "].yields is required for core.iter"
			end
			local first = fn.returns_typed[1]
			if type(first) ~= "table" or first.type ~= "Iterator" then
				return false, "functions[" .. i .. "].returns_typed[1].type must be 'Iterator' for core.iter"
			end
		end
		if fn.examples ~= nil and type(fn.examples) ~= "string" then
			return false, "functions[" .. i .. "].examples must be a string if provided"
		end
	end

	return true, nil
end

local function is_hidden_namespace(ns)
	if type(ns) ~= "string" then
		return false
	end

	return ns:match("^__") ~= nil or ns:match("%.__") ~= nil
end

local function walk_namespace(prefix, t, out)
	if type(t) ~= "table" then
		return
	end

	if is_hidden_namespace(prefix) then
		return
	end

	if type(t.__schema) == "table" then
		local ok, msg = validate_schema(t.__schema)
		if not ok then
			error("Invalid __schema for " .. prefix .. ": " .. msg)
		end
		out.schemas[prefix] = t.__schema
	end

	for k, v in pairs(t) do
		if type(k) == "string" and type(v) == "table" and k ~= "__schema" and not is_hidden_namespace(k) then
			walk_namespace(prefix .. "." .. k, v, out)
		end
	end
end

local function discover()
	if _discovered ~= nil then
		return _discovered
	end

	local out = {
		schemas = {},
		functions_by_namespace = {},
		examples_by_namespace = {},
		types_by_namespace = {},
		warnings = {},
	}

	_warnings = {}
	out.warnings = _warnings

	-- Discover roots from _G (global namespace) - look for tables with __schema or any root present in _examples
	local root_set = {}

	-- First, collect roots from global tables with __schema
	for k, v in pairs(_G) do
		if type(k) == "string" and not is_hidden_namespace(k) and type(v) == "table" and type(v.__schema) == "table" then
			root_set[k] = true
		end
	end

	-- Then, add any roots from _examples cache (external examples may exist without __schema)
	if type(_examples) == "table" then
		for k, _ in pairs(_examples) do
			if type(k) == "string" and not is_hidden_namespace(k) then
				local root = k:match("^([^.]+)")
				if root then
					root_set[root] = true
				end
			end
		end
	end

	-- Walk each discovered root
	for root, _ in pairs(root_set) do
		local t = _G[root]
		if type(t) == "table" then
			walk_namespace(root, t, out)
		end
	end

	-- Build caches.
	local namespace_examples = {}
	local cached_namespace_keys = {}

	-- Track namespace-level examples from cache first (preferred)
	if type(_examples) == "table" then
		for ns, ex in pairs(_examples) do
			if type(ns) == "string" and not is_hidden_namespace(ns) then
				if type(ex) == "string" then
					namespace_examples[ns] = ex
					cached_namespace_keys[ns] = true
				else
					warn("ignoring cached example for " .. ns .. " (expected string, got " .. type(ex) .. ")")
				end
			end
		end
	end

	for ns, schema in pairs(out.schemas) do
		out.functions_by_namespace[ns] = {}

		for _, fn in ipairs(schema.functions or {}) do
			table.insert(out.functions_by_namespace[ns], fn)
		end

		-- Attach namespace-level example: prefer cache, fall back to schema.examples when it is a string
		if namespace_examples[ns] == nil and schema.examples ~= nil then
			if type(schema.examples) == "string" then
				namespace_examples[ns] = schema.examples
			else
				warn("ignoring __schema.examples for " .. ns .. " (expected string, got " .. type(schema.examples) .. ")")
			end
		end

		if schema.types ~= nil then
			out.types_by_namespace[ns] = schema.types
		end
	end

	-- Warn on cached examples without matching schema
	for ns, _ in pairs(cached_namespace_keys) do
		if out.schemas[ns] == nil then
			warn("example cache has no matching schema for namespace " .. ns)
		end
	end

	-- Optional warnings for missing method coverage (env opt-in)
	local warn_missing = os_getenv ~= nil and os_getenv("MUNRAY_MCP_WARN_MISSING_EXAMPLES") == "1"
	if warn_missing then
		for ns, fns in pairs(out.functions_by_namespace) do
			local has_namespace_example = namespace_examples[ns] ~= nil
			for _, fn in ipairs(fns) do
				local inline_example = fn.examples
				if inline_example ~= nil and type(inline_example) ~= "string" then
					warn("ignoring inline example for " .. ns .. "." .. tostring(fn.name) .. " (expected string, got " .. type(inline_example) .. ")")
					inline_example = nil
				end
				if inline_example == nil and not has_namespace_example then
					warn("no example found for " .. ns .. "." .. tostring(fn.name))
				end
			end
		end
	end

	-- Freeze namespace-level examples into output
	for ns, ex in pairs(namespace_examples) do
		out.examples_by_namespace[ns] = ex
	end

	_discovered = out
	return out
end

local function split_namespace(ns)
	local parts = {}
	for part in string.gmatch(ns, "[^.]+") do
		table.insert(parts, part)
	end
	return parts
end

local function ensure_namespace_node(tree, namespace)
	local node = tree
	for _, part in ipairs(split_namespace(namespace)) do
		local existing = node[part]
		if existing == nil then
			existing = {}
			node[part] = existing
		elseif type(existing) ~= "table" or existing.signature ~= nil then
			warn("cannot create namespace node for " .. namespace .. " because " .. part .. " is already an operation")
			return nil
		end
		node = existing
	end
	return node
end

local function build_namespace_tree(value_builder, opts)
	opts = opts or {}
	local d = discover()
	local tree = {}

	for ns, fns in pairs(d.functions_by_namespace) do
		local include_ns = true
		if opts.namespace then
			include_ns = helpers.starts_with(ns, opts.namespace)
		end

		if include_ns then
			local node = ensure_namespace_node(tree, ns)
			if node ~= nil then
				for _, fn in ipairs(fns) do
					local ok = true
					if opts.readonly ~= nil then
						ok = fn.readonly == opts.readonly
					end
					if ok and opts.search then
						local p = opts.search:lower()
						local operation = ns .. "." .. fn.name
						ok = (operation:lower():find(p, 1, true) ~= nil) or (fn.description:lower():find(p, 1, true) ~= nil)
					end

					if ok then
						local existing = node[fn.name]
						if existing ~= nil then
							warn("cannot attach operation " .. ns .. "." .. tostring(fn.name) .. " because the name is already used by a namespace")
						else
							node[fn.name] = value_builder(fn, ns)
						end
					end
				end
			end
		end
	end

	local function prune_empty(node)
		if type(node) ~= "table" then
			return false
		end

		local has_any = false
		for key, value in pairs(node) do
			if type(value) == "table" and value.signature == nil then
				if not prune_empty(value) then
					node[key] = nil
				else
					has_any = true
				end
			else
				has_any = true
			end
		end
		return has_any
	end

	prune_empty(tree)
	return tree
end

local function is_guarded(fn)
	return fn.guarded == true
end

-- Private implementation for ctx_init(opts).
local function ai_context(_)
	local d = discover()

	local function contract_summary(contract_name)
		local c = _CORE_CONTRACTS[contract_name]
		if type(c) ~= "table" then
			return nil
		end
		return {
			description = c.description,
			pattern = c.pattern,
			example = c.example,
		}
	end

	local function return_summary(fn)
		if type(fn) == "table" and type(fn.returns_contract) == "string" then
			if _CORE_CONTRACTS[fn.returns_contract] ~= nil then
				return fn.returns_contract
			end
		end
		return "unknown"
	end

	local namespaces_table = build_namespace_tree(function(fn)
		local summary = fn.signature
		if is_guarded(fn) then
			summary = summary .. "*"
		end
		return summary .. " -> " .. return_summary(fn)
	end)

	local hints = {
		global = {
			"Use schema(target) for types/docs",
			"Use examples(target) for code",
			"Ops ending with * are guarded; require guarded mode"
		}
	}

	for namespace, schema in pairs(d.schemas) do
		if is_top_level_namespace(namespace) and type(schema) == "table" and type(schema.usage_hint) == "string" then
			if hints.namespaces == nil then
				hints.namespaces = {}
			end
			hints.namespaces[namespace] = schema.usage_hint
		end
	end

	local runtime = {}
	local runtime_src = rawget(_G, "__runtime")
	if type(runtime_src) == "table" then
		if type(runtime_src.server_id) == "string" and runtime_src.server_id ~= "" then
			runtime.server_id = runtime_src.server_id
		end
	end
	if next(runtime) == nil and type(json) == "table" and type(json._empty_array) == "function" then
		runtime = json._empty_array()
	end

	return {
		contracts = {
			error = ERROR_CONTRACT.shape,
			["core.async.result"] = contract_summary("core.async.result"),
			["core.result"] = contract_summary("core.result"),
			["core.iter"] = contract_summary("core.iter"),
		},
		conventions = {
			ctx = "scope (repo, project_key, space_key)",
			data = "payload table {field=value}",
			id = "identifier (id, iid, key, sha)",
			opts = "filters/config table; optional args are marked with ?"
		},
		discovery = {
			schema = "schema(target)",
			examples = "examples(target)",
			target_format = {
				pattern = "<service> | <service>.<resource>",
				note = "Use target names from the namespaces listed in this response."
			}
		},
		hints = hints,
		iter_helpers = {"collect", "collect_tuples", "first", "take", "skip", "page"},
		runtime = runtime,
		namespaces = namespaces_table,
	}
end

-- schema(namespace)
function schema(namespace)
	local d = discover()
	local schema = d.schemas[namespace]

	if not schema then
		return nil, error_table("NOT_FOUND", "Unknown namespace: " .. namespace)
	end

	local result = {
		namespace = namespace,
		service = schema.service,
		functions = {},
	}

	for _, fn in ipairs(d.functions_by_namespace[namespace] or {}) do
		local func_schema = {
			name = fn.name,
			signature = fn.signature,
			returns_contract = fn.returns_contract,
			description = fn.description,
			guarded = is_guarded(fn),
			params = fn.params,
			returns_typed = fn.returns_typed or {},
			yields = fn.yields,
			async = fn.async,
		}

		table.insert(result.functions, func_schema)
	end

	result.types = d.types_by_namespace[namespace] or nil
	return result
end

-- Hidden bridge for Rust validation. It is not copied into MCP session environments.
function _raw_schemas()
	return discover().schemas
end

-- examples(namespace)
function examples(namespace)
	if type(namespace) ~= "string" then
		return nil
	end

	local d = discover()

	-- 1) Method-level lookup: namespace.method. Inline method examples take
	-- precedence over a file that happens to map to the same dotted key.
	local ns, method = namespace:match("^(.*)%.([^.]+)$")
	if ns and method and d.functions_by_namespace[ns] then
		for _, fn in ipairs(d.functions_by_namespace[ns] or {}) do
			if fn.name == method and type(fn.examples) == "string" then
				return fn.examples
			end
		end
	end

	-- 2) Exact namespace/file example.
	if d.examples_by_namespace[namespace] then
		return d.examples_by_namespace[namespace]
	end

	if not (ns and method and d.functions_by_namespace[ns]) then
		return nil
	end

	-- 3) Namespace-level fallback.
	if d.examples_by_namespace[ns] then
		return d.examples_by_namespace[ns]
	end

	-- 4) Service-level fallback.
	local service = ns:match("^([^.]+)")
	if service and d.examples_by_namespace[service] then
		return d.examples_by_namespace[service]
	end

	return nil
end

-- Public discovery entrypoint. The implementation remains private so session
-- code can use discovery without receiving cache-control internals.
function ctx_init(opts)
	return ai_context(opts)
end
