-- BigQuery SQL Parser Unit Tests
-- Tests for gcloud.bigquery.__test_strip_literals_and_comments

test.describe("GCloud BigQuery - Parser")

test.assert_not_nil(gcloud, "gcloud namespace should exist")
test.assert_not_nil(gcloud.bigquery, "gcloud.bigquery namespace should exist")
test.assert_eq(type(gcloud.bigquery.__test_strip_literals_and_comments), "function", "test hook should exist")

local strip = gcloud.bigquery.__test_strip_literals_and_comments

local function assert_strips(query, must_contain, must_not_contain)
	local out = strip(query)
	for _, s in ipairs(must_contain or {}) do
		test.assert(out:find(s, 1, true) ~= nil, "expected output to contain: " .. s)
	end
	for _, s in ipairs(must_not_contain or {}) do
		test.assert(out:find(s, 1, true) == nil, "expected output to NOT contain: " .. s)
	end
	return out
end

test.describe("Parser - String Literals")

assert_strips("SELECT 'hello' FROM table", { "SELECT", "FROM" }, { "hello" })
assert_strips('SELECT "column" FROM table', { "SELECT", "FROM" }, { "column" })
assert_strips("SELECT 'can''t' FROM table", { "SELECT", "FROM" }, { "can''t" })
assert_strips("SELECT 'can\\'t' FROM table", { "SELECT", "FROM" }, { "can\\'t" })
assert_strips('SELECT "say \\"hello\\"" FROM table', { "SELECT", "FROM" }, { "hello" })

-- Backticks treated as protected region for keyword scanning
assert_strips("SELECT `update` FROM `dataset.table`", { "SELECT", "FROM" }, { "update", "dataset.table" })

-- Newlines are preserved for line/position stability
local out = strip("SELECT 'line1\nline2' FROM table")
test.assert(out:find("\n", 1, true) ~= nil, "should preserve newline")


test.describe("Parser - Comments")

assert_strips("SELECT col -- this is a comment\nFROM table", { "SELECT", "FROM" }, { "this is a comment" })
assert_strips("SELECT /* comment */ col FROM table", { "SELECT", "FROM" }, { "comment" })
assert_strips("SELECT 'this -- is not a comment' FROM table", { "SELECT", "FROM" }, { "this" })


test.describe("Parser - Unclosed Literals/Comments")

-- Fail-safe behavior: unclosed syntax returns original query
local q1 = "SELECT 'unclosed FROM table"
test.assert_eq(strip(q1), q1, "unclosed single quote should return original")

local q2 = 'SELECT "unclosed FROM table'
test.assert_eq(strip(q2), q2, "unclosed double quote should return original")

local q3 = "SELECT /* unclosed comment FROM table"
test.assert_eq(strip(q3), q3, "unclosed block comment should return original")


test.describe("Parser - Mixed")

local q = [[
SELECT
  'string with '' escape',
  "column",
  -- line comment
  /* block comment */ value
FROM `dataset.table`
WHERE x = 'test\'s'
]]
local mixed = strip(q)
test.assert(mixed:find("SELECT", 1, true) ~= nil, "should preserve SELECT")
test.assert(mixed:find("FROM", 1, true) ~= nil, "should preserve FROM")
test.assert(mixed:find("WHERE", 1, true) ~= nil, "should preserve WHERE")
test.assert(mixed:find("string with", 1, true) == nil, "should strip string content")
test.assert(mixed:find("line comment", 1, true) == nil, "should strip comments")
test.assert(mixed:find("block comment", 1, true) == nil, "should strip block comments")

test.summary()
