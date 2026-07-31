-- BigQuery Query Function Tests
-- Validation, error handling, and guard rails.

test.describe("GCloud BigQuery - Query Validation")

test.assert_not_nil(gcloud, "gcloud namespace should exist")
test.assert_not_nil(gcloud.bigquery, "gcloud.bigquery namespace should exist")
test.assert_eq(type(gcloud.bigquery.query), "function", "gcloud.bigquery.query should be a function")
test.assert_eq(type(gcloud.bigquery.show), "function", "gcloud.bigquery.show should be a function")


test.describe("Query - Required Params")

local _, err1 = gcloud.bigquery.query(nil, "SELECT 1")
test.assert_not_nil(err1, "should error on missing project")
test.assert_eq(err1.code, "MISSING_REQUIRED_FIELD", "should return MISSING_REQUIRED_FIELD")

local _, err2 = gcloud.bigquery.query("test-project-123", nil)
test.assert_not_nil(err2, "should error on missing query")
test.assert_eq(err2.code, "MISSING_REQUIRED_FIELD", "should return MISSING_REQUIRED_FIELD")

local _, err3 = gcloud.bigquery.query("   ", "SELECT 1")
test.assert_not_nil(err3, "whitespace-only project should fail validation")
test.assert_eq(err3.code, "INVALID_FIELD_VALUE", "whitespace-only project should be invalid")

local _, err4 = gcloud.bigquery.query("test-project-123", "")
test.assert_not_nil(err4, "empty query should be missing")
test.assert_eq(err4.code, "MISSING_REQUIRED_FIELD", "empty query should be treated as missing")


test.describe("Query - Project ID Validation")

local _, err5 = gcloud.bigquery.query("test", "SELECT 1")
test.assert_not_nil(err5, "should reject project ID < 6 chars")
test.assert_eq(err5.code, "INVALID_FIELD_VALUE", "should return INVALID_FIELD_VALUE")

local _, err6 = gcloud.bigquery.query(string.rep("a", 31), "SELECT 1")
test.assert_not_nil(err6, "should reject project ID > 30 chars")
test.assert_eq(err6.code, "INVALID_FIELD_VALUE", "should return INVALID_FIELD_VALUE")

local _, err7 = gcloud.bigquery.query("TestProject", "SELECT 1")
test.assert_not_nil(err7, "should reject uppercase in project")
test.assert_eq(err7.code, "INVALID_FIELD_VALUE", "should return INVALID_FIELD_VALUE")

local _, err8 = gcloud.bigquery.query("test_project", "SELECT 1")
test.assert_not_nil(err8, "should reject underscores in project")
test.assert_eq(err8.code, "INVALID_FIELD_VALUE", "should return INVALID_FIELD_VALUE")

local _, err9 = gcloud.bigquery.query("test--project", "SELECT 1")
test.assert_not_nil(err9, "should reject consecutive hyphens")
test.assert_eq(err9.code, "INVALID_FIELD_VALUE", "should return INVALID_FIELD_VALUE")

-- Valid project ids should not fail validation (may still CLI_ERROR)
for _, proj in ipairs({ "test-project", "my-gcp-project-123", "project-2024", "a1b2c3" }) do
	local _, err = gcloud.bigquery.query(proj, "SELECT 1", {dry_run = true})
	if err then
		test.assert(err.code ~= "INVALID_FIELD_VALUE", "should accept valid project: " .. proj)
	end
end


test.describe("Query - Size Limit")

local huge_query = "SELECT " .. string.rep("1,", 600000) .. "1"
local _, err10 = gcloud.bigquery.query("test-project-123", huge_query)
test.assert_not_nil(err10, "should reject queries > 1MB")
test.assert_eq(err10.code, "VALIDATION_FAILED", "should return VALIDATION_FAILED")


test.describe("Query - max_rows Validation")

local _, err11 = gcloud.bigquery.query("test-project-123", "SELECT 1", {max_rows = -1})
test.assert_not_nil(err11, "should reject negative max_rows")
test.assert_eq(err11.code, "INVALID_MAX_ROWS", "should return INVALID_MAX_ROWS")

local _, err12 = gcloud.bigquery.query("test-project-123", "SELECT 1", {max_rows = "100"})
test.assert_not_nil(err12, "should reject non-numeric max_rows")
test.assert_eq(err12.code, "INVALID_MAX_ROWS", "should return INVALID_MAX_ROWS")

local _, err13 = gcloud.bigquery.query("test-project-123", "SELECT 1", {max_rows = 100000})
test.assert_not_nil(err13, "should reject max_rows > limit")
test.assert_eq(err13.code, "MAX_ROWS_EXCEEDED", "should return MAX_ROWS_EXCEEDED")

-- max_rows at limit should not fail validation (may still CLI_ERROR)
local _, err14 = gcloud.bigquery.query("test-project-123", "SELECT 1", {max_rows = 10000, dry_run = true})
if err14 then
	test.assert(err14.code ~= "MAX_ROWS_EXCEEDED" and err14.code ~= "INVALID_MAX_ROWS", "should accept max_rows=10000")
end


test.describe("Show/Describe - Required Params and Table Validation")

local _, err15 = gcloud.bigquery.describe("test-project-123", nil)
test.assert_not_nil(err15, "should error on missing table")
test.assert_eq(err15.code, "MISSING_REQUIRED_FIELD", "should return MISSING_REQUIRED_FIELD")

local _, err16 = gcloud.bigquery.describe("test-project-123", "dataset.table;cat")
test.assert_not_nil(err16, "should reject dangerous table chars")
test.assert_eq(err16.code, "INVALID_FIELD_VALUE", "should return INVALID_FIELD_VALUE")

for _, tbl in ipairs({ "dataset.table", "my-project:dataset.table", "`dataset-name`.`table-name`", "dataset_123.table_456" }) do
	local _, err = gcloud.bigquery.describe("test-project-123", tbl)
	if err then
		test.assert(err.code ~= "INVALID_FIELD_VALUE", "should accept valid table identifier: " .. tbl)
	end
end

-- Test backward compatibility alias
local _, err_compat = gcloud.bigquery.show("test-project-123", "dataset.table")
test.assert(not err_compat or err_compat.code ~= "INVALID_FIELD_VALUE", "show() alias should work")


test.describe("PII Redaction")

local _, err17 = gcloud.bigquery.query(
	"test-project-123",
	"INSERT INTO table VALUES (1) -- email=user@example.com " .. string.rep("x", 200)
)
test.assert_not_nil(err17, "should block mutation")
test.assert_eq(err17.code, "FORBIDDEN", "should return FORBIDDEN")
test.assert_not_nil(err17.context, "should include context")
if err17.context and err17.context.query then
	test.assert(#err17.context.query < 200, "should redact long query in error context")
end

test.summary()
