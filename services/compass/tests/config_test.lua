local this_file = debug.getinfo(1, "S").source:gsub("^@", "")
local this_dir = this_file:match("^(.*)/[^/]+$")
dofile(this_dir .. "/support.lua")

test.describe("Compass Service - Config Validation")

local client = compass._get_client()

client._request_impl = function(_base_url, _document, opts)
	if opts.operation_name == "CompassReady" then
		return { compass = { __typename = "CompassQuery" } }, nil
	end

	return nil, {
		code = "UNEXPECTED_OPERATION",
		message = "unexpected operation",
		recoverable = false,
	}
end

compass_test.set_config({
	base_url = nil,
	base_url_env = nil,
	email_env = nil,
	token_env = nil,
})

local ok, err = compass.ready()
test.assert_eq(ok, false, "ready should fail when required config is missing")
test.assert_not_nil(err, "ready should return a detailed validation error")
test.assert_eq(err.code, "VALIDATION_FAILED", "missing config should return VALIDATION_FAILED")
test.assert(err.message:find("COMPASS_BASE_URL or JIRA_BASE_URL", 1, true) ~= nil, "error message should mention base URL fallback vars")
test.assert_eq(err.context.checks.COMPASS_BASE_URL.configured, false, "COMPASS_BASE_URL status should be reported")
test.assert_eq(err.context.checks.JIRA_BASE_URL.configured, false, "JIRA_BASE_URL fallback status should be reported")
test.assert(err.message:find("COMPASS_EMAIL or JIRA_EMAIL", 1, true) ~= nil, "error message should mention email fallback vars")
test.assert(err.message:find("COMPASS_API_TOKEN or JIRA_API_TOKEN", 1, true) ~= nil, "error message should mention token fallback vars")
test.assert_eq(err.context.checks.COMPASS_EMAIL.configured, false, "COMPASS_EMAIL status should be reported")
test.assert_eq(err.context.checks.JIRA_EMAIL.configured, false, "JIRA_EMAIL fallback status should be reported")
test.assert_eq(err.context.checks.COMPASS_API_TOKEN.configured, false, "COMPASS_API_TOKEN status should be reported")
test.assert_eq(err.context.checks.JIRA_API_TOKEN.configured, false, "JIRA_API_TOKEN fallback status should be reported")

compass_test.set_config({
	base_url = "https://example.atlassian.net",
	base_url_env = "JIRA_BASE_URL",
	email_env = "JIRA_EMAIL",
	token_env = "JIRA_API_TOKEN",
})

ok, err = compass.ready()
test.assert_eq(ok, true, "ready should accept Jira base URL and credential fallbacks")
test.assert_eq(err, nil, "fallback config should not return an error")

compass_test.set_config({
	base_url = "https://example.atlassian.net",
	base_url_env = "COMPASS_BASE_URL",
	email_env = "JIRA_EMAIL",
	token_env = "COMPASS_API_TOKEN",
})

ok, err = compass.ready()
test.assert_eq(ok, true, "ready should accept Jira email fallback")
test.assert_eq(err, nil, "Jira email fallback should not return an error")
