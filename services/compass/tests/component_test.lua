-- luacheck: globals compass

local this_file = debug.getinfo(1, "S").source:gsub("^@", "")
local this_dir = this_file:match("^(.*)/[^/]+$")
dofile(this_dir .. "/support.lua")

test.describe("Compass Service - Component Functions")


compass_test.set_config({
	base_url = "https://example.atlassian.net",
	base_url_env = "COMPASS_BASE_URL",
	email_env = "COMPASS_EMAIL",
	token_env = "COMPASS_API_TOKEN",
})
local client = compass._get_client()
local last_documents = {}

client._request_impl = function(base_url, document, opts)
	last_documents[opts.operation_name] = document
	if opts.operation_name == "CompassReady" then
		return { compass = { __typename = "CompassQuery" } }, nil
	end

	if opts.operation_name == "CompassCloudId" then
		return {
			tenantContexts = {
				{ cloudId = "cloud-123" },
			},
		}, nil
	end

	if opts.operation_name == "CompassComponents" then
		return {
			compass = {
				components = {
					{ id = opts.variables.ids[1], name = "Payments" },
					{ id = opts.variables.ids[2], name = "Ledger" },
				},
			},
		}, nil
	end

	if opts.operation_name == "CompassComponent" then
		return {
			compass = {
				component = { id = opts.variables.id, name = "Payments" },
			},
		}, nil
	end

	if opts.operation_name == "EnvelopeCheck" then
		return {
			data = { compass = { component = { id = opts.variables.id, name = "Payments" } } },
			extensions = { traceId = "trace-1" },
			http = { status = 200 },
		}, nil
	end

	return nil, {
		code = "UNEXPECTED_OPERATION",
		message = "unexpected operation",
		context = { operation_name = opts.operation_name, base_url = base_url, document = document },
		recoverable = false,
	}
end

test.describe("Compass ready")
local ok, err = compass.ready()
test.assert_eq(ok, true, "ready should succeed with stubbed client")
test.assert_eq(err, nil, "ready error should be nil")

test.describe("Compass components")
local items, items_err = compass.components({ "comp-1", "comp-2" })
test.assert_eq(items_err, nil, "components error should be nil")
test.assert_eq(#items, 2, "components should return two items")
test.assert_eq(items[1].id, "comp-1", "first component id should match")
test.assert_eq(items[2].name, "Ledger", "second component name should match")

local single, single_err = compass.component("comp-1")
test.assert_eq(single_err, nil, "component error should be nil")
test.assert_eq(single.id, "comp-1", "single component id should match")

local with_custom_fields, with_custom_fields_err = compass.component("comp-1", {
	include_custom_fields = true,
})
test.assert_eq(with_custom_fields_err, nil, "component with include_custom_fields should succeed")
test.assert_eq(with_custom_fields.id, "comp-1", "component with include_custom_fields should still return data")
test.assert(last_documents.CompassComponent:find("customFields", 1, true) ~= nil, "component document should include customFields when include_custom_fields is true")

local full_component, full_component_err = compass.component("comp-1", {
	field_set = "full",
})
test.assert_eq(full_component_err, nil, "component with field_set=full should succeed")
test.assert_eq(full_component.id, "comp-1", "component with field_set=full should still return data")
test.assert(last_documents.CompassComponent:find("customFields", 1, true) ~= nil, "component document should include customFields when field_set is full")

test.describe("Compass component selection validation")
local invalid_flag, invalid_flag_err = compass.component("comp-1", {
	include_custom_fields = "yes",
})
test.assert_eq(invalid_flag, nil, "invalid include_custom_fields should not return a component")
test.assert_not_nil(invalid_flag_err, "invalid include_custom_fields should return an error")
test.assert_eq(invalid_flag_err.code, "INVALID_FIELD_VALUE", "invalid include_custom_fields should be validation error")

local with_extra, with_extra_err = compass.component("comp-1", {
	extra_selection = {
		{ name = "customFields", fields = {
			{ name = "definition", fields = { "id", "name" } },
		} },
	},
})
test.assert_eq(with_extra_err, nil, "component with extra selection should succeed")
test.assert_eq(with_extra.id, "comp-1", "component with extra selection should still return data")
test.assert(last_documents.CompassComponent:find("customFields", 1, true) ~= nil, "component document should include customFields")

local invalid_selection, invalid_selection_err = compass.component("comp-1", {
	extra_selection = { { fields = { "id" } } },
})
test.assert_eq(invalid_selection, nil, "invalid selection should not return a component")
test.assert_not_nil(invalid_selection_err, "invalid selection should return an error")
test.assert_eq(invalid_selection_err.code, "VALIDATION_FAILED", "invalid selection should be validation error")

local conflicting_selection, conflicting_selection_err = compass.component("comp-1", {
	field_set = "minimal",
	selection = { "id" },
})
test.assert_eq(conflicting_selection, nil, "selection should not be allowed with field_set")
test.assert_not_nil(conflicting_selection_err, "conflicting selection should return an error")
test.assert_eq(conflicting_selection_err.code, "VALIDATION_FAILED", "conflicting selection should be a validation error")

local raw_selection, raw_selection_err = compass.component("comp-1", {
	selection = "id",
})
test.assert_eq(raw_selection, nil, "raw string selection should not be accepted")
test.assert_not_nil(raw_selection_err, "raw string selection should return an error")
test.assert_eq(raw_selection_err.code, "VALIDATION_FAILED", "raw string selection should be a validation error")

local _, too_many_err = compass.components({
	"1","2","3","4","5","6","7","8","9","10",
	"11","12","13","14","15","16","17","18","19","20",
	"21","22","23","24","25","26","27","28","29","30","31"
})
test.assert_not_nil(too_many_err, "components should fail when ids exceed limit")
test.assert_eq(too_many_err.code, "VALIDATION_FAILED", "too-many-ids should be validation error")

local env, env_err = client.request("query EnvelopeCheck { compass { component(id: \"x\") { id } } }", { id = "comp-1" }, {
	operation_name = "EnvelopeCheck",
	response_mode = "envelope",
})
test.assert_eq(env_err, nil, "direct envelope request should succeed")
test.assert_eq(env.extensions.traceId, "trace-1", "envelope should preserve extensions")

compass._cloud_id = nil
local cloud_id, cloud_id_err = client.get_cloud_id()
test.assert_eq(cloud_id_err, nil, "cloud id lookup should succeed")
test.assert_eq(cloud_id, "cloud-123", "cloud id lookup should use shared client request path")
test.assert_eq(last_documents.CompassCloudId, "query CompassCloudId($hostName: String!) {\n\ttenantContexts(hostNames: [$hostName]) {\n\t\tcloudId\n\t}\n}", "cloud id lookup should use the shared cloud id document")

test.describe("Compass client helpers")
local headers, headers_err = client.make_headers({ experimental_apis = { "compass-beta", "another-beta" } })
test.assert_eq(headers_err, nil, "make_headers should succeed")
test.assert_eq(headers[3].name, "X-ExperimentalApi", "first repeated header name should match")
test.assert_eq(headers[3].value, "compass-beta", "first repeated header value should match")
test.assert_eq(headers[4].value, "another-beta", "second repeated header value should match")

local valid, valid_err = client.validate_base_url("https://example.atlassian.net")
test.assert_eq(valid, true, "host root base url should be valid")
test.assert_eq(valid_err, nil, "valid base url should not return an error")

local invalid = nil
invalid, valid_err = client.validate_base_url("https://example.atlassian.net/gateway/api/graphql")
test.assert_eq(invalid, false, "gateway path should be rejected")
test.assert_not_nil(valid_err, "invalid base url should return an error")
