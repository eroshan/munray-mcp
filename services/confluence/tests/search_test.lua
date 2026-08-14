test.describe("Confluence Search - Namespace")

test.assert_not_nil(confluence.search, "confluence.search namespace should exist")
test.assert_eq(type(confluence.search.find), "function", "confluence.search.find should be a function")
test.assert_eq(type(confluence.search.pages), "function", "confluence.search.pages should be a function")

test.describe("Confluence Search - Schema Discovery")

local schema = capabilities.schema("confluence.search")
test.assert_not_nil(schema, "confluence.search schema should exist")
test.assert_eq(schema.namespace, "confluence.search", "schema namespace should be correct")
test.assert_eq(schema.service, "confluence", "schema service should be confluence")

local has_find = false
local has_pages = false
for _, func in ipairs(schema.functions or {}) do
	if func.name == "find" then
		has_find = true
		test.assert_eq(func.readonly, true, "search.find should not be guarded")
		test.assert_eq(func.returns_contract, "core.iter", "search.find should return iterator contract")
		test.assert_eq(func.yields, "SearchResult", "search.find should yield SearchResult")
	end
	if func.name == "pages" then
		has_pages = true
		test.assert_eq(func.readonly, true, "search.pages should not be guarded")
		test.assert_eq(func.returns_contract, "core.iter", "search.pages should return iterator contract")
		test.assert_eq(func.yields, "SearchResult", "search.pages should yield SearchResult")
	end
end

test.assert(has_find, "search schema should include find function")
test.assert(has_pages, "search schema should include pages function")

test.describe("Confluence Search - Input Validation")

local result, err = confluence.search.find(nil)
test.assert_nil(result, "search.find should return nil for missing cql")
test.assert_not_nil(err, "search.find should return structured error for missing cql")
test.assert_eq(err.code, "MISSING_REQUIRED_FIELD", "search.find should return MISSING_REQUIRED_FIELD")

result, err = confluence.search.find("")
test.assert_nil(result, "search.find should return nil for empty cql")
test.assert_not_nil(err, "search.find should return structured error for empty cql")
test.assert_eq(err.code, "MISSING_REQUIRED_FIELD", "search.find should return MISSING_REQUIRED_FIELD")

result, err = confluence.search.pages(nil)
test.assert_nil(result, "search.pages should return nil for missing query")
test.assert_not_nil(err, "search.pages should return structured error for missing query")
test.assert_eq(err.code, "MISSING_REQUIRED_FIELD", "search.pages should return MISSING_REQUIRED_FIELD")

result, err = confluence.search.pages("")
test.assert_nil(result, "search.pages should return nil for empty query")
test.assert_not_nil(err, "search.pages should return structured error for empty query")
test.assert_eq(err.code, "MISSING_REQUIRED_FIELD", "search.pages should return MISSING_REQUIRED_FIELD")

test.describe("Confluence Search - Request Construction")

local original_list_impl = confluence._client._list_impl
local captured = {}
confluence._client._list_impl = function(method, base_url, path, opts)
	captured.method = method
	captured.base_url = base_url
	captured.path = path
	captured.opts = opts

	local items = {
		{ title = "Runbook", url = "https://example.atlassian.net/wiki/x/1" },
		{ title = "Playbook", url = "https://example.atlassian.net/wiki/x/2" },
	}
	local index = 0
	return function()
		index = index + 1
		return items[index], { page = 1 }
	end
end

confluence._config = {
	base_url = "https://example.atlassian.net/wiki",
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}
confluence._auth = { kind = "basic" }

local results = helpers.collect(confluence.search.find("siteSearch ~ 'runbook' AND type = page", {
	cqlcontext = { spaceKey = "DOC", contentId = 55 },
	expand = { "content.space", "space.homepage" },
	excerpt = "highlight",
	include_archived_spaces = true,
	start = 25,
	limit = 10,
	per_page = 5,
}), { limit = 2 })

test.assert_eq(#results, 2, "search.find iterator should yield stubbed results")
test.assert_eq(captured.method, "GET", "search.find should use GET")
test.assert_eq(captured.base_url, "https://example.atlassian.net/wiki", "search.find should use normalized base URL")
test.assert_eq(captured.path, "/rest/api/search", "search.find should target the REST search endpoint")
test.assert_eq(captured.opts.query.cql, "siteSearch ~ 'runbook' AND type = page", "search.find should pass cql")
test.assert_eq(captured.opts.query.expand, "content.space,space.homepage", "search.find should join expand values")
test.assert_eq(captured.opts.query.excerpt, "highlight", "search.find should pass excerpt")
test.assert_eq(captured.opts.query.includeArchivedSpaces, true, "search.find should pass includeArchivedSpaces")
test.assert_eq(captured.opts.pagination.kind, "offset", "search.find should use offset pagination")
test.assert_eq(captured.opts.pagination.items_path, "results", "search.find should extract results array")
test.assert_eq(captured.opts.pagination.offset_param, "start", "search.find should paginate with start")
test.assert_eq(captured.opts.pagination.limit_param, "limit", "search.find should paginate with limit")
test.assert_eq(captured.opts.pagination.start_offset, 25, "search.find should pass start offset")
test.assert_eq(captured.opts.pagination.total_path, "totalSize", "search.find should use totalSize for totals")
test.assert_eq(captured.opts.limit, 10, "search.find should pass overall limit")
test.assert_eq(captured.opts.per_page, 5, "search.find should pass per-page size")
test.assert_eq(type(captured.opts.query.cqlcontext), "string", "search.find should encode cqlcontext as string")
test.assert(captured.opts.query.cqlcontext:match('"spaceKey"%s*:%s*"DOC"') ~= nil, "cqlcontext should include spaceKey")
test.assert(captured.opts.query.cqlcontext:match('"contentId"%s*:%s*55') ~= nil, "cqlcontext should include contentId")

test.describe("Confluence Search - Pages Wrapper")

local page_results = helpers.collect(confluence.search.pages("runbook", {
	limit = 3,
	excerpt = "highlight",
}), { limit = 2 })

test.assert_eq(#page_results, 2, "search.pages iterator should yield stubbed results")
test.assert_eq(captured.path, "/rest/api/search", "search.pages should target the REST search endpoint")
test.assert_eq(captured.opts.query.cql, 'siteSearch ~ "runbook" AND type = page', "search.pages should build page-scoped CQL")
test.assert_eq(captured.opts.query.excerpt, "highlight", "search.pages should pass excerpt through")
test.assert_eq(captured.opts.limit, 3, "search.pages should pass overall limit")

local escaped_results = helpers.collect(confluence.search.pages('run"book\\path', {
	limit = 2,
}), { limit = 1 })
test.assert_eq(#escaped_results, 1, "search.pages should still return stubbed results for escaped queries")
test.assert_eq(captured.opts.query.cql, 'siteSearch ~ "run\\"book\\\\path" AND type = page', "search.pages should escape quotes and backslashes for CQL")

result, err = confluence.search.pages("bad\1query")
test.assert_nil(result, "search.pages should return nil for unsupported control characters")
test.assert_not_nil(err, "search.pages should return structured error for unsupported control characters")
test.assert_eq(err.code, "VALIDATION_FAILED", "search.pages should return VALIDATION_FAILED for unsupported control characters")

confluence._client._list_impl = original_list_impl

test.summary()
