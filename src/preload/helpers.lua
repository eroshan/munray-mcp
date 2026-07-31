-- preload/helpers.lua
-- Table and utility functions

helpers = {}

helpers.__schema = {
	namespace = "helpers",
	service = "core",
	functions = {
		{
			name = "collect",
			path = "helpers.collect",
			signature = "(iterator, opts)",
			returns_contract = "core.result",
			mutating = false,
			description = "Collect iterator results into an array of tuple rows. Each row contains all values returned by one iterator step. Options: limit (max rows), max_pages (pagination limit), filter (predicate function), transform (map function)",
			params = {
				{ name = "iterator", type = "Iterator" },
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Options: {limit: number, max_pages: number, filter: function, transform: function}"
				}
			},
			returns_typed = {
				{ name = "result", type = "table" },
				{ name = "err", type = "core.error|nil" }
			},
			examples = [[
-- Self-contained iterator helper
local function make_iter(max_items, per_page)
	local i = 0
	per_page = per_page or max_items
	return function()
		i = i + 1
		if i > max_items then
			return nil
		end
		local page = math.floor((i - 1) / per_page) + 1
		return { n = i }, { page = page }
	end
end

-- Basic collection (all items)
local all, err = helpers.collect(make_iter(10, 3))
if err then error(err.message) end
print("Found", #all, "items")

-- With limit option (max items)
local limited, err2 = helpers.collect(make_iter(10, 3), { limit = 5 })
if err2 then error(err2.message) end
print("Limited to", #limited, "items")

-- With filter option
local evens, err3 = helpers.collect(make_iter(10, 3), {
	filter = function(row)
		local item = row[1]
		return (item.n % 2) == 0
	end
})
if err3 then error(err3.message) end
print("Even count", #evens)

-- With transform option
local tens, err4 = helpers.collect(make_iter(10, 3), {
	limit = 4,
	transform = function(row) return { row[1].n * 10 } end
})
if err4 then error(err4.message) end
local rendered = {}
for _, row in ipairs(tens) do rendered[#rendered + 1] = row[1] end
print("Transformed:", table.concat(rendered, ", "))

-- With max_pages to limit pagination (requires iterator meta.page)
local page_limited, err5 = helpers.collect(make_iter(10, 3), { max_pages = 1 })
if err5 then error(err5.message) end
print("Max page 1 count", #page_limited)

-- NOTE: For simple limiting, helpers.take() is simpler:
local taken, err6 = helpers.take(make_iter(10, 3), 5)
if err6 then error(err6.message) end
print("Taken", #taken)
]],
		},
		{
			name = "copy",
			path = "helpers.copy",
			signature = "(t)",
			returns_contract = "core.result",
			mutating = false,
			description = "Shallow copy a table",
			params = { { name = "t", type = "table" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "filter",
			path = "helpers.filter",
			signature = "(arr, pred)",
			returns_contract = "core.result",
			mutating = false,
			description = "Filter array by predicate function",
			params = { { name = "arr", type = "table" }, { name = "pred", type = "function" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "map",
			path = "helpers.map",
			signature = "(arr, fn)",
			returns_contract = "core.result",
			mutating = false,
			description = "Map array through transformation function",
			params = { { name = "arr", type = "table" }, { name = "fn", type = "function" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "find",
			path = "helpers.find",
			signature = "(arr, pred)",
			returns_contract = "core.result",
			mutating = false,
			description = "Return the first array item that matches the predicate, or nil if none match.",
			params = { { name = "arr", type = "table" }, { name = "pred", type = "function" } },
			returns_typed = { { name = "result", type = "any|nil" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "starts_with",
			path = "helpers.starts_with",
			signature = "(str, prefix)",
			returns_contract = "core.result",
			mutating = false,
			description = "Return true when a string starts with the given prefix.",
			params = { { name = "str", type = "string" }, { name = "prefix", type = "string" } },
			returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "contains",
			path = "helpers.contains",
			signature = "(str, substr)",
			returns_contract = "core.result",
			mutating = false,
			description = "Return true when a string contains the given substring.",
			params = { { name = "str", type = "string" }, { name = "substr", type = "string" } },
			returns_typed = { { name = "result", type = "boolean" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "keys",
			path = "helpers.keys",
			signature = "(t)",
			returns_contract = "core.result",
			mutating = false,
			description = "Return the sorted keys of a table as an array.",
			params = { { name = "t", type = "table" } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "get_in",
			path = "helpers.get_in",
			signature = "(obj, path, default)",
			returns_contract = "core.result",
			mutating = false,
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
			path = "helpers.first",
			signature = "(iterator)",
			returns_contract = "core.result",
			mutating = false,
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
			path = "helpers.take",
			signature = "(iterator, n)",
			returns_contract = "core.result",
			mutating = false,
			description = "Take N iterator rows and return an array of tuple rows",
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
			path = "helpers.page",
			signature = "(iterator, page_num, page_size)",
			returns_contract = "core.result",
			mutating = false,
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

-- Get first tuple from an iterator
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

-- Take N items from an iterator
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
	local result = empty_array()
	for i, v in ipairs(arr) do
		result[i] = fn(v, i)
	end
	return result, nil
end

-- Find first match
function helpers.find(arr, pred)
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
	local result = {}
	for k in pairs(t) do
		table.insert(result, k)
	end
	table.sort(result)
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

-- Collect iterator results into an array of tuple rows
-- helpers.collect(iterator, opts) -> array
-- Options:
--   limit: maximum number of rows to collect
--   max_pages: maximum number of pages to fetch (if iterator supports pagination metadata)
--   filter: function(item) -> boolean to filter items
--   transform: function(item) -> transformed_item to transform items
-- Throws on iterator errors with added context
function helpers.collect(iterator, opts)
	if type(iterator) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.collect: iterator must be a function",
			recoverable = false,
		}
	end

	opts = opts or {}
	if type(opts) ~= "table" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.collect: opts must be a table",
			recoverable = false,
		}
	end

	local limit = opts.limit
	if limit ~= nil and (type(limit) ~= "number" or limit < 0) then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.collect: opts.limit must be a non-negative number",
			recoverable = false,
		}
	end

	local max_pages = opts.max_pages or 0  -- 0 means no limit
	if type(max_pages) ~= "number" or max_pages < 0 then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.collect: opts.max_pages must be a non-negative number",
			recoverable = false,
		}
	end

	local filter_fn = opts.filter
	if filter_fn ~= nil and type(filter_fn) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.collect: opts.filter must be a function",
			recoverable = false,
		}
	end

	local transform_fn = opts.transform
	if transform_fn ~= nil and type(transform_fn) ~= "function" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "helpers.collect: opts.transform must be a function",
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

	-- Wrap iterator calls in pcall and return structured errors.
	local function safe_next()
		local packed = table.pack(pcall(iterator))
		local status = packed[1]
		if not status then
			return nil, wrap_iterator_error("helpers.collect: iterator error: ", packed[2])
		end
		return pack_tuple(table.unpack(packed, 2, packed.n)), nil
	end

	while true do
		local tuple, err = safe_next()
		if err then
			return nil, err
		end

		-- Iterator exhausted
		if tuple[1] == nil then
			break
		end
		seen_count = seen_count + 1

		-- Track page count if metadata available
		local meta = tuple[2]
		if type(meta) == "table" and meta.page then
			local current_page = meta.page
			if current_page > page_count then
				page_count = current_page
				-- Check max_pages limit (break after completing max_pages)
				if max_pages > 0 and page_count > max_pages then
					break
				end
			end
		end

		-- Apply filter if provided
		if filter_fn and not filter_fn(tuple, seen_count) then
			goto continue
		end

		-- Apply transform if provided
		local final_item = tuple
		if transform_fn then
			final_item = transform_fn(tuple, seen_count)
		end

		table.insert(result, final_item)
		count = count + 1

		-- Check limit
		if limit ~= nil and count >= limit then
			break
		end

		::continue::
	end

	return result, nil
end
