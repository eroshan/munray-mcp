-- Test jira service capabilities and basic functionality

test.describe("Jira Service - Namespace")

test.assert_not_nil(jira, "jira namespace should exist")
test.assert_not_nil(jira.issue, "jira.issue namespace should exist")
test.assert_not_nil(jira.project, "jira.project namespace should exist")
test.assert_not_nil(jira.field, "jira.field namespace should exist")

test.describe("Jira Service - Function Types")

test.assert_eq(type(jira.issue.get), "function", "jira.issue.get should be a function")
test.assert_eq(type(jira.issue.find), "function", "jira.issue.find should be a function")
test.assert_eq(type(jira.issue.create), "function", "jira.issue.create should be a function")
test.assert_eq(type(jira.issue.update), "function", "jira.issue.update should be a function")
test.assert_eq(type(jira.issue.transition), "function", "jira.issue.transition should be a function")
test.assert_eq(type(jira.project.get), "function", "jira.project.get should be a function")
test.assert_eq(type(jira.field.list), "function", "jira.field.list should be a function")

test.describe("Jira Service - Schema Discovery")

-- Test jira.issue schema
local issue_schema = capabilities.schema("jira.issue")
test.assert_not_nil(issue_schema, "jira.issue schema should exist")
test.assert_eq(issue_schema.namespace, "jira.issue", "issue schema namespace should be correct")
test.assert_eq(issue_schema.service, "jira", "issue schema service should be jira")
test.assert_not_nil(issue_schema.functions, "issue schema should have functions")
test.assert(#issue_schema.functions > 0, "issue schema should have at least one function")

-- Check for specific functions
local has_get = false
local has_find = false
local has_create = false
local has_update = false
local has_transition = false

for _, func in ipairs(issue_schema.functions) do
	if func.name == "get" then
		has_get = true
		test.assert_eq(func.readonly, true, "issue.get should not be guarded")
	end
	if func.name == "find" then
		has_find = true
		test.assert_eq(func.readonly, true, "issue.find should not be guarded")
	end
	if func.name == "create" then
		has_create = true
		test.assert_eq(func.readonly, false, "issue.create should be guarded")
	end
	if func.name == "update" then
		has_update = true
		test.assert_eq(func.readonly, false, "issue.update should be guarded")
	end
	if func.name == "transition" then
		has_transition = true
		test.assert_eq(func.readonly, false, "issue.transition should be guarded")
	end
end

test.assert(has_get, "issue schema should include get function")
test.assert(has_find, "issue schema should include find function")
test.assert(has_create, "issue schema should include create function")
test.assert(has_update, "issue schema should include update function")
test.assert(has_transition, "issue schema should include transition function")

-- Test jira.field schema
local field_schema = capabilities.schema("jira.field")
test.assert_not_nil(field_schema, "jira.field schema should exist")
test.assert_eq(field_schema.namespace, "jira.field", "field schema namespace should be correct")
test.assert_eq(field_schema.service, "jira", "field schema service should be jira")
test.assert_not_nil(field_schema.functions, "field schema should have functions")
test.assert(#field_schema.functions > 0, "field schema should have at least one function")

local has_field_list = false
for _, func in ipairs(field_schema.functions) do
	if func.name == "list" then
		has_field_list = true
		test.assert_eq(func.signature, "(opts)", "field.list signature should match")
		test.assert_eq(func.readonly, true, "field.list should not be guarded")
		test.assert_eq(func.returns_contract, "core.iter", "field.list should return an iterator")
		test.assert_eq(func.yields, "Field", "field.list should yield Field values")
	end
end

test.assert(has_field_list, "field schema should include list function")

test.describe("Jira Service - Ready Check")

-- Test that ready() function exists
test.assert_eq(type(jira.ready), "function", "jira.ready should be a function")

-- Note: We can't test actual ready() functionality without credentials
-- That should be in integration tests

test.describe("Jira Service - AI Context")

local context = capabilities.ai_context()
test.assert_not_nil(context, "ai_context should return a table")
test.assert_not_nil(context.namespaces, "ai_context should have namespaces field")
test.assert_not_nil(context.namespaces.jira, "ai_context should include jira namespace")
test.assert_not_nil(context.namespaces.jira.issue, "ai_context should include jira.issue namespace")
test.assert_not_nil(context.namespaces.jira.issue.get, "ai_context should include jira.issue.get operation")

-- Check if jira is mentioned (it might not be if not configured, but should be in schema)
local schemas = capabilities.schemas({ namespace = "jira" })
test.assert_not_nil(schemas.jira, "jira schemas should be registered")
test.assert_not_nil(schemas.jira.issue, "jira.issue schema should be nested under jira")
test.assert_not_nil(schemas.jira.issue.get, "jira.issue.get schema should be nested under jira.issue")

test.describe("Jira Service - Tier 1 Features: Subtasks/Parent/Hierarchy")

-- Test Tier 1 schema additions
local has_subtasks = false
local has_parent = false
local has_hierarchy = false

for _, func in ipairs(issue_schema.functions) do
	if func.name == "subtasks" then
		has_subtasks = true
		test.assert_eq(func.signature, "(parent_key, opts)", "subtasks signature should match")
		test.assert_eq(func.readonly, true, "subtasks should not be guarded")
	elseif func.name == "parent" then
		has_parent = true
		test.assert_eq(func.signature, "(child_key, opts)", "parent signature should match")
		test.assert_eq(func.readonly, true, "parent should not be guarded")
	elseif func.name == "hierarchy" then
		has_hierarchy = true
		test.assert_eq(func.signature, "(issue_key, opts)", "hierarchy signature should match")
		test.assert_eq(func.readonly, true, "hierarchy should not be guarded")
	end
end

test.assert(has_subtasks, "subtasks function should exist in schema")
test.assert(has_parent, "parent function should exist in schema")
test.assert(has_hierarchy, "hierarchy function should exist in schema")

-- Test function callability
test.assert_eq(type(jira.issue.subtasks), "function", "jira.issue.subtasks should be a function")
test.assert_eq(type(jira.issue.parent), "function", "jira.issue.parent should be a function")
test.assert_eq(type(jira.issue.hierarchy), "function", "jira.issue.hierarchy should be a function")

test.describe("Jira Service - Tier 1 Features: Input Validation")

-- Test subtasks with missing parent_key
local result, err = jira.issue.subtasks(nil)
test.assert_eq(result, nil, "subtasks should return nil for invalid input")
test.assert_not_nil(err, "subtasks should return error for invalid input")
test.assert_eq(err.code, "VALIDATION_FAILED", "subtasks should return VALIDATION_FAILED error code")

-- Test parent with missing child_key
result, err = jira.issue.parent("")
test.assert_eq(result, nil, "parent should return nil for invalid input")
test.assert_not_nil(err, "parent should return error for invalid input")
test.assert_eq(err.code, "VALIDATION_FAILED", "parent should return VALIDATION_FAILED error code")

-- Test hierarchy with missing issue_key
result, err = jira.issue.hierarchy(nil)
test.assert_eq(result, nil, "hierarchy should return nil for invalid input")
test.assert_not_nil(err, "hierarchy should return error for invalid input")
test.assert_eq(err.code, "VALIDATION_FAILED", "hierarchy should return VALIDATION_FAILED error code")

-- Test field.list with invalid opts type
result, err = jira.field.list("target")
test.assert_eq(result, nil, "field.list should return nil for invalid opts type")
test.assert_not_nil(err, "field.list should return error for invalid opts type")
test.assert_eq(err.code, "VALIDATION_FAILED", "field.list should return VALIDATION_FAILED for invalid opts type")

-- Test field.list with invalid query type
result, err = jira.field.list({ query = 123 })
test.assert_eq(result, nil, "field.list should return nil for invalid query type")
test.assert_not_nil(err, "field.list should return error for invalid query type")
test.assert_eq(err.code, "VALIDATION_FAILED", "field.list should return VALIDATION_FAILED for invalid query type")

-- Test field.list with invalid limit = 0
result, err = jira.field.list({ limit = 0 })
test.assert_eq(result, nil, "field.list should return nil for zero limit")
test.assert_not_nil(err, "field.list should return error for zero limit")
test.assert_eq(err.code, "VALIDATION_FAILED", "field.list should return VALIDATION_FAILED for zero limit")
test.assert_eq(err.message, "opts.limit must be a positive number when provided", "field.list should require a positive limit")

-- Test field.list with negative limit
result, err = jira.field.list({ limit = -1 })
test.assert_eq(result, nil, "field.list should return nil for negative limit")
test.assert_not_nil(err, "field.list should return error for negative limit")
test.assert_eq(err.code, "VALIDATION_FAILED", "field.list should return VALIDATION_FAILED for negative limit")
test.assert_eq(err.message, "opts.limit must be a positive number when provided", "field.list should require a positive limit")

test.describe("Jira Service - v2.0 API: Transition Function")

-- Test transition function exists
test.assert_eq(type(jira.issue.transition), "function", "jira.issue.transition should be a function")

-- In readonly service-pack tests, guarded functions are blocked by the core wrapper
-- before service-level input validation executes.
result, err = jira.issue.transition(nil, "31")
test.assert_eq(result, nil, "transition should return nil in readonly mode")
test.assert_not_nil(err, "transition should return error in readonly mode")
test.assert_eq(err.code, "GUARDED_TOOL_REQUIRED", "transition should be blocked in readonly mode")

result, err = jira.issue.transition("PROJ-123", nil)
test.assert_eq(result, nil, "transition should return nil in readonly mode")
test.assert_not_nil(err, "transition should return error in readonly mode")
test.assert_eq(err.code, "GUARDED_TOOL_REQUIRED", "transition should be blocked in readonly mode")

test.describe("Jira Service - v2.0 API: Standardized Error Format")

-- Test that errors include standardized fields
result, err = jira.issue.get("")
test.assert_not_nil(err, "get should return error for empty key")
test.assert_not_nil(err.code, "error should have code field")
test.assert_not_nil(err.message, "error should have message field")
test.assert_not_nil(err.suggestion, "error should have suggestion field")
test.assert_eq(type(err.recoverable), "boolean", "error should have boolean recoverable field")

test.summary()
