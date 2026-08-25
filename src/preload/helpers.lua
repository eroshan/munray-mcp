-- preload/helpers.lua
-- Table and utility functions

helpers = {}

helpers.__schema = {
	namespace = "helpers",
	service = "core",
	functions = {
		{
			name = "collect",
			signature = "(iterator, opts)",
			returns_contract = "core.result",
			guarded = false,
			description = "Collect the primary value yielded by each iterator step. Auxiliary values, including pagination metadata, are not returned. Options: limit (max items), max_pages (pagination limit), filter (predicate function), transform (map function).",
			params = {
				{ name = "iterator", type = "Iterator" },
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Options: {limit: number, max_pages: number, filter: function(item, index), transform: function(item, index)}"
				}
			},
			returns_typed = {
				{ name = "result", type = "table" },
				{ name = "err", type = "core.error|nil" }
			},
			examples = [[
-- The iterator yields an item and auxiliary page metadata.
local function make_iter(max_items, per_page)
	local i = 0
	per_page = per_page or max_items
	return function()
		i = i + 1
		if i > max_items then return nil end
		local page = math.floor((i - 1) / per_page) + 1
		return { n = i }, { page = page }
	end
end

-- collect returns the primary items, not { item, metadata } tuples.
local all, err = helpers.collect(make_iter(10, 3))
if err then error(err.message) end
print(all[1].n) -- 1

local evens, err2 = helpers.collect(make_iter(10, 3), {
	filter = function(item) return (item.n % 2) == 0 end,
	transform = function(item) return item.n * 10 end,
})
if err2 then error(err2.message) end
print(table.concat(evens, ", ")) -- 20, 40, ...

-- Opt in to every value returned by each iterator step.
local tuples, err3 = helpers.collect_tuples(make_iter(2, 1))
if err3 then error(err3.message) end
print(tuples[1][1].n, tuples[1][2].page) -- 1  1
]],
		},
		{
			name = "collect_tuples",
			signature = "(iterator, opts)",
			returns_contract = "core.result",
			guarded = false,
			description = "Collect all values yielded by each iterator step as packed tuple rows. Use only when auxiliary iterator values are required.",
			params = {
				{ name = "iterator", type = "Iterator" },
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Options: {limit: number, max_pages: number, filter: function(tuple, index), transform: function(tuple, index)}"
				}
			},
			returns_typed = {
				{ name = "result", type = "table" },
				{ name = "err", type = "core.error|nil" }
			},
		},
		{
			name = "copy",
			signature = "(t)",
			returns_contract = "core.result",
			guarded = false,
			description = "Shallow copy a table",
			params = { { name = "t", type = "table" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "filter",
			signature = "(arr, pred)",
			returns_contract = "core.result",
			guarded = false,
			description = "Filter array by predicate function",
			params = { { name = "arr", type = "table" }, { name = "pred", type = "function" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "map",
			signature = "(arr, fn)",
			returns_contract = "core.result",
			guarded = false,
			description = "Map array through transformation function",
			params = { { name = "arr", type = "table" }, { name = "fn", type = "function" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "find",
			signature = "(arr, pred)",
			returns_contract = "core.result",
			guarded = false,
			description = "Return the first array item that matches the predicate, or nil if none match.",
			params = { { name = "arr", type = "table" }, { name = "pred", type = "function" } },
			returns_typed = { { name = "result", type = "any|nil" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "starts_with",
			signature = "(str, prefix)",
			returns_contract = "core.result",
			guarded = false,
			description = "Return true when a string starts with the given prefix.",
			params = { { name = "str", type = "string" }, { name = "prefix", type = "string" } },
			returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "contains",
			signature = "(str, substr)",
			returns_contract = "core.result",
			guarded = false,
			description = "Return true when a string contains the given substring.",
			params = { { name = "str", type = "string" }, { name = "substr", type = "string" } },
			returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "keys",
			signature = "(t)",
			returns_contract = "core.result",
			guarded = false,
			description = "Return the sorted keys of a table as an array.",
			params = { { name = "t", type = "table" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "get_in",
			signature = "(obj, path, default)",
			returns_contract = "core.result",
			guarded = false,
			description = "Safely get a nested value from a table using a key path (table of keys or dot-separated string). Returns default if missing.",
			params = {
				{ name = "obj", type = "table" },
				{ name = "path", type = "table|string", description = "Key path, e.g. {'fields','status','name'} or 'fields.status.name'" },
				{ name = "default", type = "any", optional = true, description = "Returned when path is missing (defaults to nil)" },
			},
			returns_typed = { { name = "result", type = "any" }, { name = "err", type = "core.error|nil" } },
			examples = [[
-- Avoid nil-index errors on partially-populated API objects
-- Instead of: issue.fields.issuetype.name
-- Use:
local issue = { fields = { summary = "Hello" } }

local issue_type = helpers.get_in(issue, { "fields", "issuetype", "name" }, "Unknown")
assert(issue_type == "Unknown")

-- Dot-path form also works
local status = helpers.get_in(issue, "fields.status.name", "Unknown")
assert(status == "Unknown")

-- Missing default returns nil
local summary = helpers.get_in(issue, { "fields", "summary" })
assert(summary == "Hello")
]],
		},
		{
			name = "first",
			signature = "(iterator)",
			returns_contract = "core.result",
			guarded = false,
			description = "Get first tuple row from iterator. Returns nil if iterator is empty.",
			params = {
				{ name = "iterator", type = "Iterator" },
			},
			returns_typed = {
				{ name = "item", type = "any" },
				{ name = "err", type = "core.error|nil" }
			},
			examples = [[
-- Get first open MR
local row, err = helpers.first(gitlab.mr.list(repo, {state = "opened"}))
if err then error(err.message) end
local mr = row and row[1]
if mr then
  print("First open MR:", mr.title)
else
  print("No open MRs found")
end

-- Get most recent failed pipeline
local pipeline_row, err2 = helpers.first(gitlab.pipeline.list(repo, {status = "failed"}))
if err2 then error(err2.message) end
local pipeline = pipeline_row and pipeline_row[1]
]],
		},
		{
			name = "take",
			signature = "(iterator, n)",
			returns_contract = "core.result",
			guarded = false,
			description = "Take N primary iterator values and return them as an array",
			params = {
				{ name = "iterator", type = "Iterator" },
				{ name = "n", type = "number", description = "Number of items to take" },
			},
			returns_typed = {
				{ name = "items", type = "table" },
				{ name = "err", type = "core.error|nil" }
			},
			examples = [[
-- Get 5 most recent pipelines
local recent, err = helpers.take(gitlab.pipeline.list(repo), 5)
if err then error(err.message) end
print("Got", #recent, "pipelines")

-- Get 10 most recent issues
local issues, err2 = helpers.take(jira.issue.list("PROJ"), 10)
if err2 then error(err2.message) end
]],
		},
		{
			name = "page",
			signature = "(iterator, page_num, page_size)",
			returns_contract = "core.result",
			guarded = false,
			description = "Get a specific page from iterator (1-indexed) as tuple rows. Useful for manual pagination.",
			params = {
				{ name = "iterator", type = "Iterator" },
				{ name = "page_num", type = "number", description = "Page number (1-indexed)" },
				{ name = "page_size", type = "number", description = "Items per page" },
			},
			returns_typed = {
				{ name = "items", type = "table" },
				{ name = "err", type = "core.error|nil" }
			},
			examples = [[
-- Get second page of 50 issues
local page2, err = helpers.page(jira.issue.list("PROJ"), 2, 50)
if err then error(err.message) end
print("Page 2 has", #page2, "issues")

-- Get first page
local page1, err2 = helpers.page(gitlab.mr.list(repo), 1, 20)
if err2 then error(err2.message) end
]],
		},
	},
}

-- Shallow copy a table
function helpers.copy(t)
	if type(t) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.copy: t must be a table",
			recoverable = false,
		}
	end

	local result = {}
	for k, v in pairs(t) do
		result[k] = v
	end
	return result, nil
end

local function wrap_iterator_error(_prefix, err_value)
	return errutil.coerce_public(err_value, {
		code = "ITERATION_FAILED",
		message = "Iteration failed",
		recoverable = false,
	})
end

local function empty_array()
	if type(json) == "table" and type(json._empty_array) == "function" then
		return json._empty_array()
	end
	return {}
end

local function mark_array(t)
	if type(json) == "table" and type(json._mark_array) == "function" then
		return json._mark_array(t)
	end
	local mt = getmetatable(t) or {}
	mt.__mcp_json_array = true
	return setmetatable(t, mt)
end

local function pack_tuple(...)
	return mark_array(table.pack(...))
end

-- Get first tuple from an iterator. Use helpers.collect for primary values.
-- helpers.first(iterator) -> (tuple, err)
-- Returns nil if iterator is empty
function helpers.first(iterator)
	local function safe_next()
		local packed = table.pack(pcall(iterator))
		local status = packed[1]
		if not status then
			return nil, wrap_iterator_error("helpers.first: iterator error: ", packed[2])
		end
		return pack_tuple(table.unpack(packed, 2, packed.n)), nil
	end

	local tuple, err = safe_next()
	if err then
		return nil, err
	end
	if tuple[1] == nil then
		return nil, nil
	end

	return tuple, nil
end

-- Take N primary iterator values.
-- helpers.take(iterator, n) -> (items[], err)
function helpers.take(iterator, n)
	if type(n) ~= "number" or n < 0 then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.take: n must be a non-negative number",
			recoverable = false,
		}
	end

	if n == 0 then
		return empty_array(), nil
	end

	local items, err = helpers.collect(iterator, { limit = n })
	if err then
		return nil, err
	end
	if type(items) == "table" and next(items) == nil then
		return empty_array(), nil
	end
	return items, nil
end

-- Get a specific page from an iterator
-- helpers.page(iterator, page_num, page_size) -> (items[], err)
-- page_num is 1-indexed
function helpers.page(iterator, page_num, page_size)
	if type(page_num) ~= "number" or page_num < 1 then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.page: page_num must be a positive number (1-indexed)",
			recoverable = false,
		}
	end

	if type(page_size) ~= "number" or page_size < 1 then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.page: page_size must be a positive number",
			recoverable = false,
		}
	end

	-- Calculate how many items to skip
	local to_skip = (page_num - 1) * page_size

	-- Skip to the start of the desired page
	local skipped = 0
	local function safe_next()
		local packed = table.pack(pcall(iterator))
		local status = packed[1]
		if not status then
			return nil, wrap_iterator_error("helpers.page: iterator error: ", packed[2])
		end
		return pack_tuple(table.unpack(packed, 2, packed.n)), nil
	end

	-- Skip phase
	while skipped < to_skip do
		local tuple, err = safe_next()
		if err then
			return nil, err
		end
		if tuple[1] == nil then
			-- Iterator exhausted before reaching page
			return empty_array(), nil
		end
		skipped = skipped + 1
	end

	-- Collect phase - take page_size items
	local result = empty_array()
	local count = 0

	while count < page_size do
		local tuple, err = safe_next()
		if err then
			return nil, err
		end

		if tuple[1] == nil then
			break
		end

		table.insert(result, tuple)
		count = count + 1
	end

	return result, nil
end

-- Filter array by predicate
function helpers.filter(arr, pred)
	if type(arr) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.filter: arr must be a table",
			recoverable = false,
		}
	end
	if type(pred) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.filter: pred must be a function",
			recoverable = false,
		}
	end

	local result = empty_array()
	for i, v in ipairs(arr) do
		if pred(v, i) then
			table.insert(result, v)
		end
	end
	return result, nil
end

-- Map array through function
function helpers.map(arr, fn)
	if type(arr) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.map: arr must be a table",
			recoverable = false,
		}
	end
	if type(fn) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.map: fn must be a function",
			recoverable = false,
		}
	end

	local result = empty_array()
	for i, v in ipairs(arr) do
		result[i] = fn(v, i)
	end
	return result, nil
end

-- Find first match
function helpers.find(arr, pred)
	if type(arr) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.find: arr must be a table",
			recoverable = false,
		}
	end
	if type(pred) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.find: pred must be a function",
			recoverable = false,
		}
	end

	for i, v in ipairs(arr) do
		if pred(v, i) then return v, nil end
	end
	return nil, nil
end

-- Check if string starts with prefix
function helpers.starts_with(str, prefix)
	if type(str) ~= "string" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.starts_with: str must be a string",
			recoverable = false,
		}
	end
	if type(prefix) ~= "string" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.starts_with: prefix must be a string",
			recoverable = false,
		}
	end
	return str:sub(1, #prefix) == prefix, nil
end

-- Check if string contains substring
function helpers.contains(str, substr)
	if type(str) ~= "string" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.contains: str must be a string",
			recoverable = false,
		}
	end
	if type(substr) ~= "string" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.contains: substr must be a string",
			recoverable = false,
		}
	end
	return str:find(substr, 1, true) ~= nil, nil
end

-- Get keys of a table
function helpers.keys(t)
	if type(t) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.keys: t must be a table",
			recoverable = false,
		}
	end

	local result = {}
	for k in pairs(t) do
		table.insert(result, k)
	end

	-- Lua's default sort comparator cannot compare values of different types.
	-- Keep the result deterministic for mixed-key tables by grouping key types,
	-- then using a type-appropriate comparison within each group.
	local type_order = {
		number = 1,
		string = 2,
		boolean = 3,
		table = 4,
		["function"] = 5,
		thread = 6,
		userdata = 7,
	}
	table.sort(result, function(a, b)
		local type_a, type_b = type(a), type(b)
		if type_a ~= type_b then
			return (type_order[type_a] or 99) < (type_order[type_b] or 99)
		end
		if type_a == "number" or type_a == "string" then
			return a < b
		end
		if type_a == "boolean" then
			return not a and b
		end
		return tostring(a) < tostring(b)
	end)
	return result, nil
end

-- Safely get a nested value from a table.
-- path can be a table of keys, or a dot-separated string.
-- Returns default (or nil) if any segment is missing.
function helpers.get_in(obj, path, default)
	if obj == nil then
		return default, nil
	end

	local keys
	if type(path) == "string" then
		keys = {}
		for part in string.gmatch(path, "[^%.]+") do
			if part ~= "" then
				table.insert(keys, part)
			end
		end
	elseif type(path) == "table" then
		keys = path
	else
		return default, nil
	end

	local current = obj
	for _, key in ipairs(keys) do
		if type(current) ~= "table" then
			return default, nil
		end
		current = current[key]
		if current == nil then
			return default, nil
		end
	end

	return current, nil
end

-- Collect primary iterator values by default. collect_tuples opts in to the
-- packed multi-return representation used by the original collect helper.
local function collect_iterator(iterator, opts, preserve_tuples, helper_name)
	if type(iterator) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = helper_name .. ": iterator must be a function",
			recoverable = false,
		}
	end

	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = helper_name .. ": opts must be a table",
			recoverable = false,
		}
	end

	local limit = opts.limit
	if limit ~= nil and (type(limit) ~= "number" or limit < 0) then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = helper_name .. ": opts.limit must be a non-negative number",
			recoverable = false,
		}
	end

	local max_pages = opts.max_pages or 0 -- 0 means no limit
	if type(max_pages) ~= "number" or max_pages < 0 then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = helper_name .. ": opts.max_pages must be a non-negative number",
			recoverable = false,
		}
	end

	local filter_fn = opts.filter
	if filter_fn ~= nil and type(filter_fn) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = helper_name .. ": opts.filter must be a function",
			recoverable = false,
		}
	end

	local transform_fn = opts.transform
	if transform_fn ~= nil and type(transform_fn) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = helper_name .. ": opts.transform must be a function",
			recoverable = false,
		}
	end

	if limit == 0 then
		return empty_array(), nil
	end

	local result = empty_array()
	local count = 0
	local seen_count = 0
	local page_count = 0

	local function safe_next()
		local packed = table.pack(pcall(iterator))
		if not packed[1] then
			return nil, wrap_iterator_error(helper_name .. ": iterator error: ", packed[2])
		end
		return pack_tuple(table.unpack(packed, 2, packed.n)), nil
	end

	while true do
		local tuple, err = safe_next()
		if err then return nil, err end

		-- The first *return value* is the item. This does not index into or
		-- otherwise assume an order for fields in an item table.
		local item = tuple[1]
		if item == nil then break end
		seen_count = seen_count + 1

		local meta = tuple[2]
		if type(meta) == "table" and meta.page then
			local current_page = meta.page
			if current_page > page_count then
				page_count = current_page
				if max_pages > 0 and page_count > max_pages then break end
			end
		end

		local value = preserve_tuples and tuple or item
		if filter_fn and not filter_fn(value, seen_count) then goto continue end
		if transform_fn then value = transform_fn(value, seen_count) end

		table.insert(result, value)
		count = count + 1
		if limit ~= nil and count >= limit then break end

		::continue::
	end

	return result, nil
end

-- Collect only the primary value yielded by each iterator step.
function helpers.collect(iterator, opts)
	return collect_iterator(iterator, opts, false, "helpers.collect")
end

-- Collect every value yielded by each iterator step as a packed tuple row.
function helpers.collect_tuples(iterator, opts)
	return collect_iterator(iterator, opts, true, "helpers.collect_tuples")
end
