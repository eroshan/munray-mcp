-- GCloud BigQuery Examples
-- Simple runnable snippets (use placeholders)

local PROJECT = "YOUR_GCP_PROJECT"
local TABLE = "YOUR_DATASET.YOUR_TABLE" -- e.g. dataset.table or project:dataset.table

-- BigQuery: describe table info (no schema)
local info, err = gcloud.bigquery.describe(PROJECT, TABLE)
if err then error(err.message) end

-- BigQuery: describe schema only (no merge with table info)
local info2, err2 = gcloud.bigquery.describe(PROJECT, TABLE, {schema = true})
if err2 then error(err2.message) end
local field_count = 0  -- luacheck: ignore
if info2.schema and info2.schema.fields then field_count = #info2.schema.fields end

-- BigQuery: query dry-run (estimate cost)
local estimate, err3 = gcloud.bigquery.query(
	PROJECT,
	"SELECT COUNT(*) AS total FROM `" .. TABLE .. "`",
	{dry_run = true}
)
if err3 then error(err3.message) end

-- BigQuery: query (LIMIT 10)
local rows, err4 = gcloud.bigquery.query(
	PROJECT,
	"SELECT * FROM `" .. TABLE .. "` LIMIT 10"
)
if err4 then error(err4.message) end

-- BigQuery: default row cap (bq returns up to 100 rows unless max_rows is set)
-- Pattern to check whether you hit a cap N:
-- 1) ask for LIMIT (N+1)
-- 2) set max_rows = (N+1)
-- 3) if you get (N+1) rows back, there are more than N
local N = 100
local rows_plus_one, err4b = gcloud.bigquery.query(
	PROJECT,
	"SELECT * FROM `" .. TABLE .. "` LIMIT " .. tostring(N + 1),
	{max_rows = N + 1}
)
if err4b then error(err4b.message) end
local hit_cap = (#rows_plus_one == (N + 1))
if hit_cap then
	-- Drop the extra row; keep only the first N.
	table.remove(rows_plus_one)
end

-- BigQuery: security (mutations blocked)
local _ignored, err5 = gcloud.bigquery.query(
	PROJECT,
	"DROP TABLE `" .. TABLE .. "`"
)
if not err5 or err5.code ~= "FORBIDDEN" then
	error("expected FORBIDDEN error code")
end

-- BigQuery: error handling (missing args)
local _, err6 = gcloud.bigquery.query(nil, "SELECT 1")
if not err6 or err6.code ~= "MISSING_REQUIRED_FIELD" then error("expected MISSING_REQUIRED_FIELD") end
local _, err7 = gcloud.bigquery.query(PROJECT, nil)
if not err7 or err7.code ~= "MISSING_REQUIRED_FIELD" then error("expected MISSING_REQUIRED_FIELD") end

-- Backward compatibility: show() still works
local info_compat, err_compat = gcloud.bigquery.show(PROJECT, TABLE)
if err_compat then error(err_compat.message) end
