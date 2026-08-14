-- Test gcloud service capabilities and basic functionality

test.describe("GCloud Service - Namespace")

test.assert_not_nil(gcloud, "gcloud namespace should exist")
test.assert_not_nil(gcloud.project, "gcloud.project namespace should exist")
test.assert_eq(type(gcloud.project.list), "function", "gcloud.project.list should be a function")
test.assert_not_nil(gcloud.bigquery, "gcloud.bigquery namespace should exist")
test.assert_eq(type(gcloud.bigquery.query), "function", "gcloud.bigquery.query should be a function")
test.assert_eq(type(gcloud.bigquery.show), "function", "gcloud.bigquery.show should be a function")

test.describe("GCloud Service - Schema Discovery")

-- Test that schema is defined
test.assert_not_nil(gcloud.project.__schema, "gcloud.project.__schema should exist")
test.assert_eq(gcloud.project.__schema.namespace, "gcloud.project", "namespace should be gcloud.project")
test.assert_eq(gcloud.project.__schema.service, "gcloud", "service should be gcloud")
test.assert(#gcloud.project.__schema.functions > 0, "should have at least one function")


-- Test that capabilities.schema works
local schema, err = capabilities.schema("gcloud.project")
test.assert_nil(err, "capabilities.schema should not error")
test.assert_not_nil(schema, "schema should not be nil")
test.assert_eq(schema.namespace, "gcloud.project", "schema namespace should match")

local project_list_fn = nil
for _, fn in ipairs(schema.functions) do
	if fn.name == "list" then
		project_list_fn = fn
		break
	end
end

test.assert_not_nil(project_list_fn, "project list function should exist in schema")
local project_list_opts = project_list_fn and project_list_fn.params and project_list_fn.params[1] and project_list_fn.params[1].schema or nil
test.assert_not_nil(project_list_opts, "project list opts schema should exist")
test.assert_not_nil(project_list_opts and project_list_opts.project_pattern, "project_pattern option should be documented")
test.assert_not_nil(project_list_opts and project_list_opts.force_gcp_read, "force_gcp_read option should be documented")
test.assert_nil(project_list_opts and project_list_opts.filter, "legacy filter option should be removed from schema")
test.assert_nil(project_list_opts and project_list_opts.limit, "legacy limit option should be removed from schema")

local invalid_pattern_result, invalid_pattern_err = gcloud.project.list({ project_pattern = 123 })
test.assert_nil(invalid_pattern_result, "non-string project_pattern should be rejected")
test.assert_not_nil(invalid_pattern_err, "non-string project_pattern should return an error")
test.assert_eq(invalid_pattern_err and invalid_pattern_err.code, "INVALID_FIELD_VALUE", "project_pattern should require a string")

local malformed_pattern_result, malformed_pattern_err = gcloud.project.list({ project_pattern = "[" })
test.assert_nil(malformed_pattern_result, "malformed project_pattern should be rejected")
test.assert_not_nil(malformed_pattern_err, "malformed project_pattern should return an error")
test.assert_eq(malformed_pattern_err and malformed_pattern_err.code, "INVALID_FIELD_VALUE", "project_pattern should be validated before CLI execution")

test.describe("GCloud Service - BigQuery Namespace")

-- Test that bigquery namespace exists
test.assert_not_nil(gcloud.bigquery, "gcloud.bigquery namespace should exist")
test.assert_eq(type(gcloud.bigquery.query), "function", "gcloud.bigquery.query should be a function")

-- Test that schema is defined
test.assert_not_nil(gcloud.bigquery.__schema, "gcloud.bigquery.__schema should exist")
test.assert_eq(gcloud.bigquery.__schema.namespace, "gcloud.bigquery", "namespace should be gcloud.bigquery")
test.assert_eq(gcloud.bigquery.__schema.service, "gcloud", "service should be gcloud")
test.assert(#gcloud.bigquery.__schema.functions > 0, "should have at least one function")

-- Test that capabilities.schema works
local bigquery_schema, bigquery_err = capabilities.schema("gcloud.bigquery")
test.assert_nil(bigquery_err, "capabilities.schema should not error for gcloud.bigquery")
test.assert_not_nil(bigquery_schema, "bigquery schema should not be nil")
test.assert_eq(bigquery_schema.namespace, "gcloud.bigquery", "schema namespace should match for gcloud.bigquery")

-- Test that query function has proper schema
local bigquery_fn = nil
for _, fn in ipairs(bigquery_schema.functions) do
	if fn.name == "query" then
		bigquery_fn = fn
		break
	end
end

test.assert_not_nil(bigquery_fn, "query function should exist in schema")
test.assert_eq(bigquery_fn.guarded, false, "query should not be guarded")
test.assert_eq(bigquery_fn.returns_contract, "core.result", "should follow core.result contract")
test.assert_not_nil(bigquery_fn.params, "should have params defined")
test.assert_not_nil(bigquery_fn.returns_typed, "should have returns_typed")
test.assert_eq(#bigquery_fn.params, 3, "should have three params (project, sql, opts)")
test.assert_eq(bigquery_fn.params[1].name, "project", "first param should be named project")
test.assert_eq(bigquery_fn.params[2].name, "sql", "second param should be named sql")
test.assert_eq(bigquery_fn.params[3].name, "opts", "third param should be named opts")

-- Test that show function has proper schema
local bigquery_show_fn = nil
for _, fn in ipairs(bigquery_schema.functions) do
	if fn.name == "show" then
		bigquery_show_fn = fn
		break
	end
end

test.assert_not_nil(bigquery_show_fn, "show function should exist in schema")
test.assert_eq(bigquery_show_fn.guarded, false, "show should not be guarded")
test.assert_eq(bigquery_show_fn.returns_contract, "core.result", "show should follow core.result contract")
test.assert_not_nil(bigquery_show_fn.params, "show should have params defined")
test.assert_not_nil(bigquery_show_fn.returns_typed, "show should have returns_typed")
test.assert_eq(#bigquery_show_fn.params, 3, "show should have three params (project, table, opts)")
test.assert_eq(bigquery_show_fn.params[1].name, "project", "show first param should be named project")
test.assert_eq(bigquery_show_fn.params[2].name, "table", "show second param should be named table")
test.assert_eq(bigquery_show_fn.params[3].name, "opts", "show third param should be named opts")

-- Test that describe function exists (new in v2.0)
local bigquery_describe_fn = nil
for _, fn in ipairs(bigquery_schema.functions) do
	if fn.name == "describe" then
		bigquery_describe_fn = fn
		break
	end
end

test.assert_not_nil(bigquery_describe_fn, "describe function should exist in schema")
test.assert_eq(bigquery_describe_fn.guarded, false, "describe should not be guarded")
test.assert_eq(bigquery_describe_fn.returns_contract, "core.result", "describe should follow core.result contract")

test.describe("GCloud Service - Logs Namespace")

-- Test that logs namespace exists
test.assert_not_nil(gcloud.logs, "gcloud.logs namespace should exist")
test.assert_eq(type(gcloud.logs.get), "function", "gcloud.logs.get should be a function")

-- Test that schema is defined
test.assert_not_nil(gcloud.logs.__schema, "gcloud.logs.__schema should exist")
test.assert_eq(gcloud.logs.__schema.namespace, "gcloud.logs", "namespace should be gcloud.logs")
test.assert_eq(gcloud.logs.__schema.service, "gcloud", "service should be gcloud")
test.assert(#gcloud.logs.__schema.functions > 0, "should have at least one function")

-- Test that capabilities.schema works
local logs_schema, logs_err = capabilities.schema("gcloud.logs")
test.assert_nil(logs_err, "capabilities.schema should not error for gcloud.logs")
test.assert_not_nil(logs_schema, "logs schema should not be nil")
test.assert_eq(logs_schema.namespace, "gcloud.logs", "schema namespace should match for gcloud.logs")

test.describe("GCloud Service - Logs Async Schema")

-- Test that logs.get returns task_id string and has async metadata
local logs_fn = nil
for _, fn in ipairs(logs_schema.functions) do
	if fn.name == "get" then
		logs_fn = fn
		break
	end
end

test.assert_not_nil(logs_fn, "get function should exist in schema")
test.assert_not_nil(logs_fn.async, "get function should have async metadata")
test.assert_eq(logs_fn.async.kind, "task", "async kind should be 'task'")
test.assert_eq(logs_fn.async.handle, "task_id", "async handle should be 'task_id'")
test.assert_not_nil(logs_fn.returns_typed, "should have returns_typed")
test.assert_eq(logs_fn.returns_typed[1].type, "string", "first return should be task_id string")
test.assert_eq(logs_fn.returns_typed[1].name, "task_id", "first return should be named task_id")
test.assert_eq(logs_fn.async.sequential_calls, true, "should require sequential calls")
test.assert_not_nil(logs_fn.async.usage, "should have usage guidance")

test.describe("GCloud Service - AI Context")

-- Test that gcloud appears in capabilities.ai_context (v2.0 compact format)
local context = capabilities.ai_context()
test.assert_eq(type(context), "table", "ai_context should return a table")

test.assert_not_nil(context.discovery, "ai_context should include discovery")
test.assert_not_nil(context.discovery.target_format, "ai_context should include discovery.target_format")
test.assert_eq(context.discovery.target_format.pattern, "<service> | <service>.<resource>", "ai_context should describe discovery target format")

test.summary()
