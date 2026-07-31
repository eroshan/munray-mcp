-- luacheck: globals compass

local this_file = debug.getinfo(1, "S").source:gsub("^@", "")
local this_dir = this_file:match("^(.*)/[^/]+$")
dofile(this_dir .. "/support.lua")

test.describe("Compass Service - Iterators")

compass_test.set_config({
	base_url = "https://example.atlassian.net",
	base_url_env = "COMPASS_BASE_URL",
	email_env = "COMPASS_EMAIL",
	token_env = "COMPASS_API_TOKEN",
})
compass._cloud_id = "cloud-1"

local client = compass._get_client()
local last_calls = {}

client._list_impl = function(base_url, document, opts)
	last_calls[#last_calls + 1] = {
		base_url = base_url,
		document = document,
		opts = opts,
	}

	local items = {}
	if opts.operation_name == "CompassSearchComponents" then
		items = {
			{ id = "comp-1", name = "Payments" },
			{ id = "comp-2", name = "Ledger" },
		}
	elseif opts.operation_name == "CompassComponentLogs" then
		items = {
			{ id = "log-1", action = "SET_FIELD", value = "deployed" },
			{ id = "log-2", action = "SET_FIELD", value = "healthy" },
		}
	else
		return nil, {
			code = "UNEXPECTED_OPERATION",
			message = "unexpected operation",
			context = { operation_name = opts.operation_name },
			recoverable = false,
		}
	end

	local index = 0
	return function()
		index = index + 1
		local item = items[index]
		if item == nil then
			return nil
		end
		return item, { kind = opts.pagination.kind, page = 1 }
	end, nil
end

local search_items, search_err = helpers.collect(compass.searchComponents("payments", { limit = 2, per_page = 10 }))
test.assert_eq(search_err, nil, "searchComponents collect should succeed")
test.assert_eq(#search_items, 2, "searchComponents should yield two items")
test.assert_eq(search_items[1][1].name, "Payments", "first search item should match")

local logs, logs_err = helpers.collect(compass.componentLogs("comp-1", { limit = 2, per_page = 5 }))
test.assert_eq(logs_err, nil, "componentLogs collect should succeed")
test.assert_eq(#logs, 2, "componentLogs should yield two logs")
test.assert_eq(logs[2][1].value, "healthy", "second log value should match")

test.assert_eq(#last_calls, 2, "two list operations should have been captured")

test.assert_eq(last_calls[1].opts.pagination.kind, "cursor", "search should use cursor pagination")
test.assert_eq(last_calls[1].opts.pagination.connection_path, "compass.searchComponents", "search connection_path should match")
test.assert_eq(last_calls[1].opts.pagination.cursor_variable, "query.after", "search cursor variable path should match")
test.assert_eq(last_calls[1].opts.pagination.page_size_variable, "query.first", "search page size variable path should match")
test.assert_eq(last_calls[1].opts.pagination.edges_path, "nodes", "search edges path should match payload shape")
test.assert_eq(last_calls[1].opts.pagination.node_path, "component", "search node path should extract nested component")
test.assert_eq(last_calls[1].opts.variables.cloudId, "cloud-1", "search should include cloudId")
test.assert_eq(last_calls[1].opts.variables.query.query, "payments", "search query text should be normalized")

test.assert_eq(last_calls[2].opts.pagination.connection_path, "compass.component.logs", "logs connection_path should match")
test.assert_eq(last_calls[2].opts.pagination.edges_path, "nodes", "logs should read from nodes")
test.assert_eq(last_calls[2].opts.variables.id, "comp-1", "logs component id should be normalized")

local invalid_items, invalid_err = helpers.collect(compass.searchComponents(123))
test.assert_eq(invalid_items, nil, "invalid search query should not produce items")
test.assert_not_nil(invalid_err, "invalid search query should produce iterator error")
test.assert_eq(invalid_err.code, "ITERATOR_ERROR", "invalid search query should be wrapped as iterator error")

local invalid_sort_items, invalid_sort_err = helpers.collect(compass.searchComponents("payments", { sort = 123 }))
test.assert_eq(invalid_sort_items, nil, "invalid sort should not produce items")
test.assert_not_nil(invalid_sort_err, "invalid sort should produce iterator error")
test.assert_eq(invalid_sort_err.code, "ITERATOR_ERROR", "invalid sort should be wrapped as iterator error")
