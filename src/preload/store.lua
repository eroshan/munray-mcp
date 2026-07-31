-- preload/store.lua
-- User-facing store API layer (kept separate from capabilities.lua).

if type(_raw) ~= "table" or type(_raw.store) ~= "table" then
	return
end

-- Create global store table for high-level API
store = {}

-- Thin wrappers around _raw.store.* for convenience.
function store.put(type_name, key, value, opts)
	return _raw.store.put(type_name, key, value, opts)
end

function store.get(type_name, key)
	return _raw.store.get(type_name, key)
end

function store.delete(type_name, key)
	return _raw.store.delete(type_name, key)
end

function store.keys(type_name)
	return _raw.store.keys(type_name)
end

function store.len(type_name)
	return _raw.store.len(type_name)
end

function store.clear(type_name)
	return _raw.store.clear(type_name)
end

function store.cache_get(...)
	local argc = select("#", ...)
	if argc ~= 1 then
		return nil, { code = "VALIDATION", message = "store.cache_get signature is (key)", recoverable = false }
	end
	local key = ...
	return _raw.store.cache_get(key)
end

local function to_error_v1(err, default_code)
	if err == nil then
		return nil
	end

	if type(err) == "table" then
		local code_ok = type(err.code) == "string" and err.code ~= ""
		local msg_ok = type(err.message) == "string" and err.message ~= ""
		if code_ok and msg_ok then
			if err.recoverable == nil then
				err.recoverable = false
			end
			return err
		end
	end

	return {
		code = default_code or "ERROR",
		message = tostring(err),
		recoverable = false,
	}
end


local function build_schema_expr(path, description, params, returns)
	local fn_name = string.match(path, "([^%.]+)$")
	if fn_name == nil or fn_name == "" then
		fn_name = path
	end

	local sig = "(...)"
	local params_expr = "nil"
	if type(params) == "table" and #params > 0 then
		local sig_parts = {}
		local p_items = {}
		for i, p in ipairs(params) do
			if type(p) ~= "string" or p == "" then
				return nil, { code = "VALIDATION", message = string.format("params[%d] must be a non-empty string", i), recoverable = false }
			end
			table.insert(sig_parts, p)
			table.insert(p_items, string.format("{ name = %q, type = %q }", p, "any"))
		end
		sig = "(" .. table.concat(sig_parts, ", ") .. ")"
		params_expr = "{ " .. table.concat(p_items, ", ") .. " }"
	end

	local returns_type = "any"
	if type(returns) == "string" and returns ~= "" then
		returns_type = returns
	end

	local desc = "Stored function"
	if type(description) == "string" and description ~= "" then
		desc = description
	end

	local schema_expr = string.format(
		"{ name = %q, path = %q, signature = %q, returns_contract = %q, mutating = false, description = %q, params = %s, returns_typed = { { name = %q, type = %q }, { name = %q, type = %q } } }",
		fn_name,
		path,
		sig,
		"core.result",
		desc,
		params_expr,
		"result",
		returns_type,
		"err",
		"core.error|nil"
	)

	return schema_expr, nil
end

-- store.save_snippet(path, fn_lua, opts?) -> (true|nil, err)
-- store.save_snippet(def) -> (true|nil, err)
--
-- def:
--   path: string (required)
--   description: string (optional)
--   params: {string,...} (optional)
--   returns: string (optional)
--   code: string (required)  -- Lua function literal, e.g. [[function(x) return x end]]
--   schema_expr: string (optional) -- overrides generated schema
--   example: string (optional)
local function save_snippet_impl(path, fn_lua, opts)
	if type(path) ~= "string" or path == "" then
		return nil, { code = "VALIDATION", message = "path must be a non-empty string", recoverable = false }
	end
	if type(fn_lua) ~= "string" or fn_lua == "" then
		return nil, { code = "VALIDATION", message = "fn_lua must be a non-empty string", recoverable = false }
	end

	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, { code = "VALIDATION", message = "opts must be a table if provided", recoverable = false }
	end

	local description = opts.description
	if description ~= nil and type(description) ~= "string" then
		return nil, { code = "VALIDATION", message = "opts.description must be a string if provided", recoverable = false }
	end

	local _ok, err = _raw.store.put("fn", path, fn_lua, { content_type = "lua", description = description })
	if err then
		return nil, to_error_v1(err, "STORE_PUT")
	end

	local schema_expr = opts.schema_expr
	if schema_expr ~= nil then
		if type(schema_expr) ~= "string" or schema_expr == "" then
			return nil, { code = "VALIDATION", message = "opts.schema_expr must be a non-empty string if provided", recoverable = false }
		end
		local _, schema_err = _raw.store.put("schema", path, schema_expr, { content_type = "lua", description = description })
		if schema_err then
			return nil, to_error_v1(schema_err, "STORE_PUT")
		end
	end

	local example = opts.example
	if example ~= nil then
		if type(example) ~= "string" or example == "" then
			return nil, { code = "VALIDATION", message = "opts.example must be a non-empty string if provided", recoverable = false }
		end
		-- Store a Lua expression that evaluates to a string.
		local example_expr = string.format("%q", example)
		local _, ex_err = _raw.store.put("example", path, example_expr, { content_type = "lua", description = description })
		if ex_err then
			return nil, to_error_v1(ex_err, "STORE_PUT")
		end
	end

	return true, nil
end

function store.save_snippet(a, b, c)
	-- New definition-form API: store.save_snippet({ ... })
	if type(a) == "table" and b == nil and c == nil then
		local def = a
		local path = def.path
		local description = def.description
		local code = def.code

		if type(code) == "function" then
			return nil, {
				code = "VALIDATION",
				message = "def.code must be a Lua string containing a function literal (functions cannot be persisted as values)",
				recoverable = false,
			}
		end
		if type(code) ~= "string" or code == "" then
			return nil, { code = "VALIDATION", message = "def.code must be a non-empty string", recoverable = false }
		end

		local opts = { description = description }
		if def.schema_expr ~= nil then
			opts.schema_expr = def.schema_expr
		elseif def.params ~= nil or def.returns ~= nil or def.description ~= nil then
			local schema_expr, err = build_schema_expr(path, description, def.params, def.returns)
			if err then
				return nil, err
			end
			opts.schema_expr = schema_expr
		end
		if def.example ~= nil then
			opts.example = def.example
		end

		return save_snippet_impl(path, code, opts)
	end

	-- Backwards-compatible API: store.save_snippet(path, fn_lua, opts?)
	return save_snippet_impl(a, b, c)
end

-- Attach schema for discovery.
if store.__schema == nil then
	store.__schema = {
		namespace = "store",
		service = "store",
		functions = {
			{
				name = "put",
				path = "store.put",
				signature = "(type_name, key, value, opts?)",
				returns_contract = "core.result",
				mutating = true,
				description = "Store a value under (type, key)",
				params = {
					{ name = "type_name", type = "string" },
					{ name = "key", type = "string" },
					{ name = "value", type = "any" },
					{ name = "opts", type = "table|nil" },
				},
				returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "get",
				path = "store.get",
				signature = "(type_name, key)",
				returns_contract = "core.result",
				mutating = false,
				description = "Get a value by (type, key)",
				params = {
					{ name = "type_name", type = "string" },
					{ name = "key", type = "string" },
				},
				returns_typed = { { name = "result", type = "any" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "delete",
				path = "store.delete",
				signature = "(type_name, key)",
				returns_contract = "core.result",
				mutating = true,
				description = "Delete a value by (type, key)",
				params = {
					{ name = "type_name", type = "string" },
					{ name = "key", type = "string" },
				},
				returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "keys",
				path = "store.keys",
				signature = "(type_name)",
				returns_contract = "core.result",
				mutating = false,
				description = "List keys for a type",
				params = { { name = "type_name", type = "string" } },
				returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "len",
				path = "store.len",
				signature = "(type_name)",
				returns_contract = "core.result",
				mutating = false,
				description = "Count entries for a type",
				params = { { name = "type_name", type = "string" } },
				returns_typed = { { name = "result", type = "number" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "clear",
				path = "store.clear",
				signature = "(type_name)",
				returns_contract = "core.result",
				mutating = true,
				description = "Clear all entries for a type",
				params = { { name = "type_name", type = "string" } },
				returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "cache_get",
				path = "store.cache_get",
				signature = "(key)",
				returns_contract = "core.result",
				mutating = false,
				description = "Get cache value by key",
				params = {
					{ name = "key", type = "string" },
				},
				returns_typed = { { name = "result", type = "any" }, { name = "err", type = "core.error|nil" } },
			},
			{
				name = "save_snippet",
				path = "store.save_snippet",
				signature = "(path, fn_lua, opts?) | (def)",
				returns_contract = "core.result",
				mutating = true,
				description = "Persist a stored function snippet and (optionally) its schema/example",
				params = {
					{ name = "path", type = "string|nil" },
					{ name = "fn_lua", type = "string|nil" },
					{ name = "opts", type = "table|nil" },
					{ name = "def", type = "table|nil" },
				},
				returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
			},
		},
	}
end
