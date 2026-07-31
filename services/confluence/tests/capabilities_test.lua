-- Test confluence service capabilities and basic functionality

test.describe("Confluence Service - Namespace")

test.assert_not_nil(confluence, "confluence namespace should exist")
test.assert_not_nil(confluence.page, "confluence.page namespace should exist")

test.describe("Confluence Service - Ready")

test.assert_eq(type(confluence.ready), "function", "confluence.ready should be a function")

local ok, ready_err = confluence.ready()
test.assert_eq(ok, false, "ready should be false when not configured")
test.assert_not_nil(ready_err, "ready should return error when not configured")
test.assert_eq(ready_err and ready_err.code, "VALIDATION_FAILED", "ready should return VALIDATION_FAILED when base URL is not configured")

test.describe("Confluence Service - Function Types")

test.assert_eq(type(confluence.page.get), "function", "confluence.page.get should be a function")
test.assert_eq(type(confluence.page.text), "nil", "page.text should not be exposed")
test.assert_eq(type(confluence.page.get_page), "nil", "page.get_page should not be exposed")
test.assert_eq(type(confluence.page.get_by_url), "nil", "page.get_by_url should not be exposed")

test.describe("Confluence Service - Schema Discovery")

local page_schema = capabilities.schema("confluence.page")
test.assert_not_nil(page_schema, "confluence.page schema should exist")
test.assert_eq(page_schema.namespace, "confluence.page", "page schema namespace should be correct")
test.assert_eq(page_schema.service, "confluence", "page schema service should be confluence")

test.assert_not_nil(page_schema.functions, "page schema should have functions")
test.assert(#page_schema.functions > 0, "page schema should have at least one function")

local has_get = false
local has_content = false
local has_find = false
local has_list = false
local has_create = false
local has_update = false
for _, func in ipairs(page_schema.functions) do
	if func.name == "get" then
		has_get = true
		test.assert_eq(func.mutating, false, "page.get should not be mutating")
	end
	if func.name == "content" then
		has_content = true
		test.assert_eq(func.mutating, false, "page.content should not be mutating")
	end
	if func.name == "find" then
		has_find = true
		test.assert_eq(func.mutating, false, "page.find should not be mutating")
	end
	if func.name == "list" then
		has_list = true
		test.assert_eq(func.mutating, false, "page.list should not be mutating")
	end
	if func.name == "create" then
		has_create = true
		test.assert_eq(func.mutating, true, "page.create should be mutating")
	end
	if func.name == "update" then
		has_update = true
		test.assert_eq(func.mutating, true, "page.update should be mutating")
	end
end

test.assert(has_get, "page schema should include get function")
test.assert(has_content, "page schema should include content function")
test.assert(has_find, "page schema should include find function")
test.assert(has_list, "page schema should include list function")
test.assert(has_create, "page schema should include create function")
test.assert(has_update, "page schema should include update function")

test.describe("Confluence Service - Input Validation")

local result, err = confluence.page.get(nil)
test.assert_eq(result, nil, "get should return nil for invalid input")
test.assert_not_nil(err, "get should return error for invalid input")
test.assert_eq(err and err.code, "MISSING_REQUIRED_FIELD", "get should return MISSING_REQUIRED_FIELD error code")

result, err = confluence.page.find("")
test.assert_eq(result, nil, "find should return nil for invalid input")
test.assert_not_nil(err, "find should return error for invalid input")
test.assert_eq(err and err.code, "MISSING_REQUIRED_FIELD", "find should return MISSING_REQUIRED_FIELD error code")

result, err = confluence.page.find("https://example.atlassian.net/wiki/x/abcd")
test.assert_eq(result, nil, "find should return nil for unsupported URL")
test.assert_not_nil(err, "find should return error for unsupported URL")
test.assert_eq(err and err.code, "VALIDATION_FAILED", "find should return VALIDATION_FAILED")

test.describe("Confluence Service - Base URL Normalization")

test.assert_eq(
	confluence._client._normalize_base_url("https://five9inc.atlassian.net"),
	"https://five9inc.atlassian.net/wiki",
	"should append /wiki when missing"
)
test.assert_eq(
	confluence._client._normalize_base_url("https://five9inc.atlassian.net/wiki"),
	"https://five9inc.atlassian.net/wiki",
	"should keep /wiki when already present"
)
test.assert_eq(
	confluence._client._normalize_base_url("https://five9inc.atlassian.net/jira"),
	"https://five9inc.atlassian.net/jira",
	"should preserve invalid paths so validation can reject them"
)

local expected_base_url = "https://five9inc.atlassian.net/wiki"
local expected_path = "/api/v2/pages/264995493"

test.describe("Confluence Service - Ready URL Check")

local original_ready_impl = confluence._client._request_impl
local ready_captured = {}
confluence._client._request_impl = function(method, base_url, path, req)
	ready_captured.method = method
	ready_captured.base_url = base_url
	ready_captured.path = path
	ready_captured.req = req
	return nil, nil
end

confluence._config = {
	base_url = expected_base_url,
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}

local ready_ok, ready_probe_err = confluence.ready()
test.assert_eq(ready_ok, true, "ready should succeed when /home probe succeeds")
test.assert_eq(ready_probe_err, nil, "ready should not return error on successful /home probe")
test.assert_eq(ready_captured.method, "HEAD", "ready should probe with HEAD")
test.assert_eq(ready_captured.base_url, expected_base_url, "ready should use normalized base URL")
test.assert_eq(ready_captured.path, "/home", "ready should probe the Confluence home page")
test.assert_eq(ready_captured.req and ready_captured.req.auth, nil, "ready should not require auth")

confluence._client._request_impl = original_ready_impl

test.describe("Confluence Service - URL Conversion")

local human_url = "https://five9inc.atlassian.net/wiki/spaces/CLOUD/pages/264995493/Service+Ownership"

-- Stub transport so we can assert the exact URL pieces without network.
local original_request_impl = confluence._client._request_impl
local captured = {}
confluence._client._request_impl = function(method, base_url, path, req)
	captured.method = method
	captured.base_url = base_url
	captured.path = path
	captured.req = req

	-- Minimal page payload for v2.0 API (returns full page object)
	return {
		id = "264995493",
		title = "Service Ownership",
		body = {
			storage = { value = "ok" },
		},
	}, nil
end

-- Provide config/auth so find() reaches request()
confluence._config = {
	base_url = expected_base_url,
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}
confluence._auth = { kind = "basic" }

local page, err = confluence.page.find(human_url)
test.assert_not_nil(page, "find should return page object")
test.assert_eq(err, nil, "find should not return error")

test.assert_eq(captured.method, "GET", "should use GET")
test.assert_eq(captured.base_url, expected_base_url, "should use normalized /wiki base url")
test.assert_eq(captured.path, expected_path, "should call REST v2 page path")

-- Restore
confluence._client._request_impl = original_request_impl

test.describe("Confluence Service - Error Context URL")

local original_impl2 = confluence._client._request_impl
confluence._client._request_impl = function(_method, _base_url, _path, _req)
	return nil, { code = "HTTP", message = "boom", recoverable = true }
end

confluence._config = {
	base_url = confluence._client._normalize_base_url("https://five9inc.atlassian.net"),
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}
confluence._auth = { kind = "basic" }

local _r, e = confluence._client.request("GET", "/api/v2/pages/264995493", { query = { ["body-format"] = "storage" } })
test.assert_eq(_r, nil, "request should return nil result on error")
test.assert_not_nil(e, "request should return error")
test.assert_not_nil(e.context, "error should have context")
test.assert_eq(
	e.context.full_url,
	"https://five9inc.atlassian.net/wiki/api/v2/pages/264995493?body-format=storage",
	"error context should include full_url"
)

confluence._client._request_impl = original_impl2

test.describe("Confluence Service - Invalid Base URL")

confluence._config = {
	base_url = confluence._client._normalize_base_url("https://five9inc.atlassian.net/jira"),
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}

local ready_invalid, invalid_err = confluence.ready()
test.assert_eq(ready_invalid, false, "ready should fail for invalid base URL paths")
test.assert_not_nil(invalid_err, "ready should return error for invalid base URL paths")
test.assert_eq(invalid_err.code, "VALIDATION_FAILED", "invalid base URL should return VALIDATION_FAILED")

test.summary()
