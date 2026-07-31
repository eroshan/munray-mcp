-- Security test for gcloud.bigquery.query
-- Tests forbidden keyword detection and boundary rules.

test.describe("GCloud BigQuery - Security")

test.assert_not_nil(gcloud, "gcloud namespace should exist")
test.assert_not_nil(gcloud.bigquery, "gcloud.bigquery namespace should exist")
test.assert_eq(type(gcloud.bigquery.query), "function", "gcloud.bigquery.query should be a function")

local function expect_forbidden(query, expected_keyword)
	local result, err = gcloud.bigquery.query("test-project", query)

	test.assert_eq(result, nil, "result should be nil when blocked")
	test.assert_not_nil(err, "err should be returned when blocked")
	test.assert_eq(err.code, "FORBIDDEN", "should be blocked with FORBIDDEN")
	test.assert_not_nil(err.context, "err.context should be present")
	test.assert_eq(err.context.detected_keyword, expected_keyword, "detected keyword should match")
end

local function expect_not_forbidden(query)
	-- NOTE: This call may still return API_ERROR in environments without bq/auth.
	-- We only assert it is NOT classified as a forbidden mutation.
	local _result, err = gcloud.bigquery.query("test-project", query, {dry_run = true})

	if err ~= nil then
		test.assert(err.code ~= "FORBIDDEN", "should not be flagged as forbidden mutation")
	end
end

test.describe("GCloud BigQuery - Forbidden Keywords")

expect_forbidden("INSERT INTO table VALUES (1)", "INSERT")
expect_forbidden("update table set x=1", "UPDATE")
expect_forbidden("DELETE FROM table WHERE id=1", "DELETE")
expect_forbidden("CREATE TABLE foo (id INT)", "CREATE")
expect_forbidden("DROP TABLE foo", "DROP")
expect_forbidden("MERGE INTO target USING source ON target.id = source.id", "MERGE")
expect_forbidden("GRANT SELECT ON table TO user", "GRANT")

test.describe("GCloud BigQuery - Word Boundaries")

-- Standalone keyword with punctuation/newlines should still be blocked.
expect_forbidden("SELECT 1; UPDATE;", "UPDATE")
expect_forbidden("SELECT 1\nDELETE\nFROM t", "DELETE")

-- Identifiers containing keyword substrings should NOT be blocked.
expect_not_forbidden("SELECT inserting_user FROM logs")
expect_not_forbidden("SELECT * FROM my_insert_table")

test.describe("GCloud BigQuery - Ignore Literals/Comments")

expect_not_forbidden("SELECT 1 WHERE 'Schema Update' LIKE '%Schema Update%'")
expect_not_forbidden("SELECT `update` FROM `dataset.table` LIMIT 1")
expect_not_forbidden("SELECT 1 -- UPDATE table\n")
expect_not_forbidden("SELECT 1 /* DROP TABLE */")

test.summary()
