-- gcloud.bigquery.query implementation
-- Execute BigQuery SQL queries with billing protection and security controls

-- Capture raw primitives as upvalues (security best practice)
local raw_cli_json = sys.cli.json

local DEFAULT_MAX_BYTES_BILLED = 1073741824  -- 1 GB
local DEFAULT_TIMEOUT_SECONDS = 300
local DEFAULT_BQ_MAX_ROWS = 100

local MAX_QUERY_SIZE_BYTES = 1048576 -- 1MB
local MAX_ROWS_LIMIT = 10000

-- Security: Check for forbidden SQL mutation keywords
local function strip_sql_literals_and_comments(query)
	-- Removes content inside quotes/comments by replacing with spaces.
	-- This prevents false positives like LIKE '%Schema Update%'.
	local out = {}
	local out_len = 0
	local i = 1
	local n = #query
	local state = "code" -- code|single|double|backtick|line_comment|block_comment

	while i <= n do
		local ch = query:sub(i, i)
		local nextch = ""
		if i < n then
			nextch = query:sub(i + 1, i + 1)
		end

		if state == "code" then
			if ch == "'" then
				state = "single"
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 1
			elseif ch == '"' then
				state = "double"
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 1
			elseif ch == "`" then
				state = "backtick"
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 1
			elseif ch == "-" and nextch == "-" then
				state = "line_comment"
				out_len = out_len + 1
				out[out_len] = " "
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 2
			elseif ch == "/" and nextch == "*" then
				state = "block_comment"
				out_len = out_len + 1
				out[out_len] = " "
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 2
			else
				out_len = out_len + 1
				out[out_len] = ch
				i = i + 1
			end
		elseif state == "single" then
			if ch == "\\" and i < n then
				-- Backslash escape sequence (e.g., \' , \n, \\)
				out_len = out_len + 1
				out[out_len] = " "
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 2
			elseif ch == "'" then
				if nextch == "'" then
					-- Escaped single quote inside a string literal
					out_len = out_len + 1
					out[out_len] = " "
					out_len = out_len + 1
					out[out_len] = " "
					i = i + 2
				else
					state = "code"
					out_len = out_len + 1
					out[out_len] = " "
					i = i + 1
				end
			else
				out_len = out_len + 1
				out[out_len] = (ch == "\n") and "\n" or " "
				i = i + 1
			end
		elseif state == "double" then
			if ch == "\\" and i < n then
				-- Backslash escape sequence
				out_len = out_len + 1
				out[out_len] = " "
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 2
			elseif ch == '"' then
				if nextch == '"' then
					-- Escaped double quote
					out_len = out_len + 1
					out[out_len] = " "
					out_len = out_len + 1
					out[out_len] = " "
					i = i + 2
				else
					state = "code"
					out_len = out_len + 1
					out[out_len] = " "
					i = i + 1
				end
			else
				out_len = out_len + 1
				out[out_len] = (ch == "\n") and "\n" or " "
				i = i + 1
			end
		elseif state == "backtick" then
			if ch == "`" then
				state = "code"
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 1
			else
				out_len = out_len + 1
				out[out_len] = (ch == "\n") and "\n" or " "
				i = i + 1
			end
		elseif state == "line_comment" then
			if ch == "\n" then
				state = "code"
				out_len = out_len + 1
				out[out_len] = "\n"
				i = i + 1
			else
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 1
			end
		elseif state == "block_comment" then
			if ch == "*" and nextch == "/" then
				state = "code"
				out_len = out_len + 1
				out[out_len] = " "
				out_len = out_len + 1
				out[out_len] = " "
				i = i + 2
			else
				out_len = out_len + 1
				out[out_len] = (ch == "\n") and "\n" or " "
				i = i + 1
			end
		else
			out_len = out_len + 1
			out[out_len] = " "
			i = i + 1
		end
	end

	-- Security: Check for unclosed literals/comments.
	-- If we're still in a non-code state, the query has unclosed syntax.
	-- Fail-safe: return original query so forbidden keywords are not hidden.
	if state ~= "code" then
		return query
	end

	return table.concat(out)
end

-- GCP Project ID Validation
-- Project IDs: 6-30 chars, lowercase letters, digits, hyphens
-- Must start with letter, cannot end with hyphen
local function validate_gcp_project_id(project)
	if not project or type(project) ~= "string" then
		return false, "project must be a string"
	end

	if #project < 6 or #project > 30 then
		return false, "project ID must be 6-30 characters"
	end

	if not project:match("^[a-z][a-z0-9%-]*[a-z0-9]$") then
		return false, "project ID contains invalid characters or format"
	end

	if project:match("%-%-") then
		return false, "project ID cannot contain consecutive hyphens"
	end

	return true, nil
end

-- BigQuery Table Identifier Validation
-- Format: [project:]dataset.table or dataset.table
-- Allow: letters, numbers, underscores, hyphens
-- Allow backticks around dataset/table: `dataset-name`.`table-name`
-- Block: whitespace/control chars and common shell metacharacters
local function validate_table_identifier(table_name)
	if not table_name or type(table_name) ~= "string" then
		return false, "table must be a string"
	end

	-- Trim whitespace
	table_name = table_name:match("^%s*(.-)%s*$")
	if table_name == "" then
		return false, "table cannot be empty or whitespace"
	end

	-- Block dangerous/control characters (even though CLI args are not shell-expanded)
	if table_name:match("[%c]") then
		return false, "table contains control characters"
	end
	if table_name:match("[%s]") then
		return false, "table cannot contain whitespace"
	end
	if table_name:match("[;&|<>$()\\]") then
		return false, "table contains dangerous characters (;&|<>$()\\)"
	end

	-- Optional project prefix: project:dataset.table
	local rest = table_name
	local colon_pos = table_name:find(":", 1, true)
	if colon_pos then
		local prefix = table_name:sub(1, colon_pos - 1)
		rest = table_name:sub(colon_pos + 1)
		if prefix == "" then
			return false, "table project prefix cannot be empty"
		end
		if not prefix:match("^[A-Za-z0-9_%-]+$") then
			return false, "table project prefix has invalid characters"
		end
	end

	local function is_ident(s)
		return s:match("^[A-Za-z0-9_%-]+$") ~= nil
	end
	local function is_backticked_ident(s)
		if s:sub(1, 1) ~= "`" or s:sub(-1) ~= "`" then
			return false
		end
		local inner = s:sub(2, -2)
		return inner ~= "" and inner:match("^[A-Za-z0-9_%-]+$") ~= nil
	end

	local dot_pos = rest:find(".", 1, true)
	if not dot_pos then
		return false, "table identifier format invalid (expected: dataset.table or project:dataset.table)"
	end

	local dataset = rest:sub(1, dot_pos - 1)
	local tbl = rest:sub(dot_pos + 1)
	if dataset == "" or tbl == "" then
		return false, "table identifier format invalid (missing dataset or table)"
	end

	local dataset_ok = is_ident(dataset) or is_backticked_ident(dataset)
	local table_ok = is_ident(tbl) or is_backticked_ident(tbl)
	if not dataset_ok or not table_ok then
		return false, "table identifier format invalid (expected: dataset.table or project:dataset.table)"
	end

	return true, nil
end

-- PII Protection: Redact queries in error logs
-- Queries may contain sensitive data in WHERE clauses (emails, SSNs, etc.)
local function redact_query_for_logging(query)
	if not query then
		return "[nil]"
	end

	local max_visible = 100
	if #query > max_visible then
		return query:sub(1, max_visible) .. "... [REDACTED " .. tostring(#query - max_visible) .. " chars for security]"
	end

	return query
end

local function redact_args_for_logging(args)
	if type(args) ~= "table" then
		return args
	end

	local redacted = {}
	for i, v in ipairs(args) do
		redacted[i] = v
	end

	-- For bq query, the final positional argument is the SQL string.
	if #redacted > 0 then
		redacted[#redacted] = "[REDACTED_QUERY]"
	end

	return redacted
end

local function wrap_bq_cli_error(action, raw_err, ctx)
	local context = {}
	if type(ctx) == "table" then
		for k, v in pairs(ctx) do
			context[k] = v
		end
	end

	local raw_ctx = raw_err and raw_err.context
	if type(raw_ctx) == "table" then
		if raw_ctx.exit_code ~= nil then
			context.exit_code = raw_ctx.exit_code
		end
		if raw_ctx.stderr ~= nil then
			context.stderr = raw_ctx.stderr
		end
		if raw_ctx.stdout ~= nil then
			context.stdout = raw_ctx.stdout
		end
	end

	return nil, {
		code = "API_ERROR",
		message = "bq " .. action .. " command failed: " .. ((raw_err and raw_err.message) or tostring(raw_err)),
		recoverable = true,
		suggestion = "See err.context.stderr for bq CLI details. Also check project permissions and verify BigQuery API is enabled.",
		context = context,
	}
end

-- Shared parameter validation helper
-- Reduces code duplication across query() and show()
local function _validate_required_params(opts, required_fields)
	if not opts or type(opts) ~= "table" then
		return nil, {
			code = "INVALID_OPTIONS",
			message = "opts must be a table",
			context = { opts_type = type(opts) },
			recoverable = false,
		}
	end

	for _, field_def in ipairs(required_fields) do
		local field_name = field_def.name
		local validator = field_def.validator
		local allow_whitespace_only = (field_def.allow_whitespace_only == true)
		local value = opts[field_name]

		if value == nil or value == "" then
			return nil, {
				code = "MISSING_" .. string.upper(field_name),
				message = field_name .. " parameter is required",
				context = { missing = field_name },
				recoverable = false,
			}
		end

		if type(value) == "string" and not allow_whitespace_only then
			local trimmed = value:match("^%s*(.-)%s*$")
			if trimmed == "" then
				return nil, {
					code = "MISSING_" .. string.upper(field_name),
					message = field_name .. " parameter is required",
					context = { missing = field_name },
					recoverable = false,
				}
			end
		end

		if validator then
			local valid, err_msg = validator(value)
			if not valid then
				return nil, {
					code = "INVALID_" .. string.upper(field_name),
					message = "Invalid " .. field_name .. ": " .. (err_msg or "validation failed"),
					context = {
						[field_name] = (field_name == "query") and redact_query_for_logging(value) or value,
						reason = err_msg,
					},
					recoverable = false,
				}
			end
		end
	end

	return opts, nil
end

local function contains_forbidden_sql(query)
	-- Forbidden keywords (case-insensitive, word boundaries)
	local forbidden = {
		"INSERT", "UPDATE", "DELETE", "CREATE",
		"DROP", "ALTER", "TRUNCATE", "MERGE",
		"GRANT", "REVOKE"
	}

	-- Ignore literals and comments so keywords are only detected in executable SQL.
	local cleaned = strip_sql_literals_and_comments(query)
	local query_upper = string.upper(cleaned)
	-- Word boundary matching: ensure the keyword is not part of an identifier.
	-- This catches cases like "UPDATE;" and "DELETE\n" while allowing "my_update_col".
	-- Implemented without Lua frontier patterns for compatibility.
	local function is_word_char(ch)
		-- Treat underscore as word-char as well to avoid false positives in identifiers like my_insert_table.
		return ch ~= "" and ch:match("[%w_]") ~= nil
	end

	for _, keyword in ipairs(forbidden) do
		local start_idx = 1
		while true do
			local i, j = query_upper:find(keyword, start_idx, true)
			if not i then
				break
			end

			local prev_ch = (i > 1) and query_upper:sub(i - 1, i - 1) or ""
			local next_ch = (j < #query_upper) and query_upper:sub(j + 1, j + 1) or ""

			local left_ok = (i == 1) or (not is_word_char(prev_ch))
			local right_ok = (j == #query_upper) or (not is_word_char(next_ch))

			if left_ok and right_ok then
				return true, keyword
			end

			start_idx = j + 1
		end
	end

	return false, nil
end

local function bigquery_query(project, sql, opts)
	-- Validate required positional parameters
	if not project or type(project) ~= "string" or project == "" then
		return nil, {
			code = "MISSING_REQUIRED_FIELD",
			message = "project parameter is required and must be a non-empty string",
			recoverable = false,
			suggestion = "Provide a valid GCP project ID as the first parameter",
			context = { project = project }
		}
	end

	if not sql or type(sql) ~= "string" or sql == "" then
		return nil, {
			code = "MISSING_REQUIRED_FIELD",
			message = "sql parameter is required and must be a non-empty string",
			recoverable = false,
			suggestion = "Provide a valid SQL query as the second parameter",
			context = { sql = sql }
		}
	end

	-- Validate project format
	local valid, err_msg = validate_gcp_project_id(project)
	if not valid then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "Invalid project ID: " .. (err_msg or "validation failed"),
			recoverable = false,
			suggestion = "Ensure project ID is 6-30 characters, lowercase letters/digits/hyphens, starts with letter",
			context = { project = project, reason = err_msg }
		}
	end

	-- Normalize opts
	opts = opts or {}

	-- Security: Limit query size to prevent resource exhaustion
	if #sql > MAX_QUERY_SIZE_BYTES then
		return nil, {
			code = "VALIDATION_FAILED",
			message = "Query exceeds maximum size of 1MB (" .. tostring(#sql) .. " bytes)",
			recoverable = false,
			suggestion = "Reduce query size or break into smaller queries",
			context = {
				query_size = #sql,
				max_size = MAX_QUERY_SIZE_BYTES,
			}
		}
	end

	-- 2. Security check: detect forbidden mutations
	local is_forbidden, detected_keyword = contains_forbidden_sql(sql)
	if is_forbidden then
		return nil, {
			code = "FORBIDDEN",
			message = "Query contains forbidden keyword: " .. detected_keyword,
			recoverable = false,
			suggestion = "This API only allows read-only SELECT queries. Use BigQuery console for mutations.",
			context = {
				detected_keyword = detected_keyword,
				query = redact_query_for_logging(sql),
				forbidden_keywords = {
					"INSERT", "UPDATE", "DELETE", "CREATE",
					"DROP", "ALTER", "TRUNCATE", "MERGE",
					"GRANT", "REVOKE"
				}
			}
		}
	end

	-- 3. Build bq command arguments
	-- NOTE: bq is strict about flag positioning: flags must come before the final
	-- positional argument (the SQL query string).
	local args = {"query"}

	-- Add project flag (required)
	table.insert(args, "--project_id=" .. project)

	-- Add use_legacy_sql flag (default: false for standard SQL)
	local use_legacy = opts.use_legacy_sql or false
	if use_legacy then
		table.insert(args, "--use_legacy_sql=true")
	else
		table.insert(args, "--use_legacy_sql=false")
	end

	-- Add format flag for structured output
	table.insert(args, "--format=prettyjson")

	-- bq defaults to DEFAULT_BQ_MAX_ROWS rows returned; allow callers to override explicitly.
	-- NOTE: This only affects the number of rows returned to the caller, not bytes processed.
	if not opts.dry_run then
		local max_rows = opts.max_rows
		if max_rows == nil then
			max_rows = DEFAULT_BQ_MAX_ROWS
		else
			if type(max_rows) ~= "number" then
				return nil, {
					code = "INVALID_MAX_ROWS",
					message = "max_rows must be a number",
					context = { max_rows = max_rows },
					recoverable = false,
				}
			end
			if max_rows < 0 then
				return nil, {
					code = "INVALID_MAX_ROWS",
					message = "max_rows cannot be negative",
					context = { max_rows = max_rows },
					recoverable = false,
				}
			end
			if max_rows > MAX_ROWS_LIMIT then
				return nil, {
					code = "MAX_ROWS_EXCEEDED",
					message = "max_rows cannot exceed " .. tostring(MAX_ROWS_LIMIT) .. " (requested: " .. tostring(max_rows) .. ")",
					context = {
						requested = max_rows,
						limit = MAX_ROWS_LIMIT,
					},
					recoverable = false,
				}
			end
		end
		table.insert(args, "--max_rows=" .. tostring(max_rows))
	end

	-- Add dry_run flag if requested
	if opts.dry_run then
		table.insert(args, "--dry_run")
	else
		-- Only add maximum_bytes_billed for actual queries (not dry runs)
		local max_bytes = opts.maximum_bytes_billed or DEFAULT_MAX_BYTES_BILLED
		if max_bytes and max_bytes > 0 then
			table.insert(args, "--maximum_bytes_billed=" .. tostring(max_bytes))
		end
	end

	-- Add query as the final positional argument
	table.insert(args, sql)

	-- 4. Execute via sys.cli.json primitive
	local timeout = opts.timeout or DEFAULT_TIMEOUT_SECONDS
	local result, err = raw_cli_json("bq", args, { timeout = timeout })

	if err then
		return wrap_bq_cli_error("query", err, {
			args = redact_args_for_logging(args),
			project = project,
			dry_run = opts.dry_run or false,
		})
	end

	-- 5. Enforce billing guard on dry-run cost estimates (plan: BYTES_EXCEEDED)
	-- For dry_run: result is metadata object with totalBytesProcessed, schema, etc.
	-- For normal query: result is array of row objects
	if opts.dry_run then
		local max_bytes = opts.maximum_bytes_billed
		if max_bytes == nil then
			max_bytes = DEFAULT_MAX_BYTES_BILLED
		end

		if max_bytes and max_bytes > 0 and type(result) == "table" then
			local processed = result.totalBytesProcessed
			if processed ~= nil then
				local processed_num = tonumber(processed)
				if processed_num and processed_num > max_bytes then
					return nil, {
						code = "VALIDATION_FAILED",
						message = "Query would process " .. tostring(processed) .. " bytes which exceeds maximum_bytes_billed=" .. tostring(max_bytes),
						recoverable = false,
						suggestion = "Increase maximum_bytes_billed limit or optimize query to process less data",
						context = {
							project = project,
							maximum_bytes_billed = max_bytes,
							totalBytesProcessed = processed,
							query = redact_query_for_logging(sql),
						}
					}
				end
			end
		end
	end

	return result, nil
end

gcloud.bigquery.query = bigquery_query

local function bigquery_describe(project, table, opts)
	-- Validate required positional parameters
	if not project or type(project) ~= "string" then
		return nil, {
			code = "MISSING_REQUIRED_FIELD",
			message = "project parameter is required and must be a string",
			recoverable = false,
			suggestion = "Provide a valid GCP project ID as the first parameter",
			context = { project = project }
		}
	end

	if not table or type(table) ~= "string" then
		return nil, {
			code = "MISSING_REQUIRED_FIELD",
			message = "table parameter is required and must be a string",
			recoverable = false,
			suggestion = "Provide a valid table identifier (e.g., 'dataset.table') as the second parameter",
			context = { table = table }
		}
	end

	-- Validate project format
	local valid_project, err_msg_project = validate_gcp_project_id(project)
	if not valid_project then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "Invalid project ID: " .. (err_msg_project or "validation failed"),
			recoverable = false,
			suggestion = "Ensure project ID is 6-30 characters, lowercase letters/digits/hyphens, starts with letter",
			context = { project = project, reason = err_msg_project }
		}
	end

	-- Validate table format
	local valid_table, err_msg_table = validate_table_identifier(table)
	if not valid_table then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "Invalid table identifier: " .. (err_msg_table or "validation failed"),
			recoverable = false,
			suggestion = "Use format 'dataset.table' or 'project:dataset.table'",
			context = { table = table, reason = err_msg_table }
		}
	end

	-- Normalize opts
	opts = opts or {}

	-- bq show: returns table metadata by default.
	-- When schema=true, bq returns schema-only output (often a flat array). We
	-- normalize it into { schema = { fields = [...] } }.
	local timeout = opts.timeout or DEFAULT_TIMEOUT_SECONDS

	if opts.schema == true then
		local schema_args = {
			"show",
			"--project_id=" .. project,
			"--schema",
			"--format=prettyjson",
			table,
		}

		local schema_res, schema_err = raw_cli_json("bq", schema_args, { timeout = timeout })
		if schema_err then
			return wrap_bq_cli_error("show --schema", schema_err, {
				args = schema_args,
				project = project,
				table = table,
				schema = true,
			})
		end

		if type(schema_res) == "table" and schema_res.fields ~= nil then
			return { schema = schema_res }, nil
		elseif type(schema_res) == "table" then
			return { schema = { fields = schema_res } }, nil
		end

		return { schema = { fields = {} } }, nil
	end

	local info_args = {
		"show",
		"--project_id=" .. project,
		"--format=prettyjson",
		table,
	}

	local info, err = raw_cli_json("bq", info_args, { timeout = timeout })
	if err then
		return wrap_bq_cli_error("show", err, {
			args = info_args,
			project = project,
			table = table,
			schema = false,
		})
	end

	return info, nil
end

gcloud.bigquery.describe = bigquery_describe
-- Keep backward compatibility alias
gcloud.bigquery.show = bigquery_describe

-- Testing hook (not part of public contract)
gcloud.bigquery.__test_strip_literals_and_comments = strip_sql_literals_and_comments

-- Schema metadata for capabilities discovery
gcloud.bigquery.__schema = {
	namespace = "gcloud.bigquery",
	service = "gcloud",
	description = "Google BigQuery SQL query operations with billing protection and security controls",
	functions = {
		{
			name = "query",
			signature = "(project, sql, [opts])",
			returns_contract = "core.result",
			description = "Execute BigQuery SQL query or validate with dry-run. Blocks mutations (INSERT/UPDATE/DELETE/etc). Default 1GB billing limit for safety. Returns up to 100 rows by default; set opts.max_rows to override.",
			readonly = true,
			params = {
				{
					name = "project",
					type = "string",
					optional = false,
					description = "GCP project ID (required)"
				},
				{
					name = "sql",
					type = "string",
					optional = false,
					description = "SQL query to execute (required). Mutations are blocked."
				},
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Optional query parameters",
					schema = {
						maximum_bytes_billed = {
							type = "number",
							optional = true,
							description = "Billing limit in bytes. Default: 1073741824 (1 GB). Protects against expensive queries."
						},
						dry_run = {
							type = "boolean",
							optional = true,
							description = "Validate query and estimate cost without executing. Default: false"
						},
						use_legacy_sql = {
							type = "boolean",
							optional = true,
							description = "Use legacy SQL syntax instead of standard SQL. Default: false"
						},
						timeout = {
							type = "number",
							optional = true,
							description = "Query timeout in seconds. Default: 300"
						},
						max_rows = {
							type = "number",
							optional = true,
							description = "Maximum rows to return (maps to bq --max_rows). Default is " .. tostring(DEFAULT_BQ_MAX_ROWS) .. " when omitted. To check whether you hit a cap N, request LIMIT (N+1) with max_rows=(N+1) and see if #rows == (N+1)."
						}
					}
				}
			},
			returns_typed = {
				{
					name = "result",
					type = "QueryRow[]|DryRunResult",
					description = "Array of rows (normal query) or metadata object (dry_run=true)"
				},
				{
					name = "err",
					type = "core.error|nil",
					description = "Structured error: {code, message, recoverable, suggestion, context}. For CLI/API failures, inspect err.context.stderr/exit_code. Codes: MISSING_REQUIRED_FIELD, INVALID_FIELD_VALUE, VALIDATION_FAILED, FORBIDDEN, API_ERROR"
				}
			},
			examples = string.format([[
-- Dry-run query to validate and estimate cost
local estimate, err = gcloud.bigquery.query(
	"my-project",
	"SELECT COUNT(*) FROM `dataset.table`",
	{dry_run = true}
)
if err then error(err.message) end
return estimate

-- Execute query with billing protection
local rows, err = gcloud.bigquery.query(
	"my-project",
	"SELECT name, count FROM dataset.table WHERE count > 100 LIMIT 10",
	{max_rows = 10, maximum_bytes_billed = 1073741824}
)
if err then
	print("Error: " .. err.message)
	if err.suggestion then print("Suggestion: " .. err.suggestion) end
	if err.context and err.context.stderr then print("bq stderr: " .. tostring(err.context.stderr)) end
	return
end
return rows
]], DEFAULT_BQ_MAX_ROWS)
		}
		,
		{
			name = "describe",
			signature = "(project, table, [opts])",
			returns_contract = "core.result",
			description = "Show BigQuery table/view metadata. Returns table info by default; when opts.schema=true returns schema-only.",
			readonly = true,
			params = {
				{
					name = "project",
					type = "string",
					optional = false,
					description = "GCP project ID (required)",
				},
				{
					name = "table",
					type = "string",
					optional = false,
					description = "Table identifier (required), e.g. 'dataset.table' or 'project:dataset.table'",
				},
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Optional parameters",
					schema = {
						schema = {
							type = "boolean",
							optional = true,
							description = "If true, include schema details (maps to bq --schema). Default: false",
						},
						timeout = {
							type = "number",
							optional = true,
							description = "Command timeout in seconds. Default: 300",
						},
					},
				},
			},
			returns_typed = {
				{
					name = "result",
					type = "TableInfo",
					description = "If opts.schema is false: table/view metadata. If opts.schema is true: schema-only ({schema={fields=[...]}}).",
				},
				{
					name = "err",
					type = "core.error|nil",
					description = "Structured error: {code, message, recoverable, suggestion, context}. For CLI/API failures, inspect err.context.stderr/exit_code. Codes: MISSING_REQUIRED_FIELD, INVALID_FIELD_VALUE, API_ERROR",
				},
			},
			examples = [[
-- Show schema only
local res, err = gcloud.bigquery.describe("my-project", "dataset.table", {schema = true})
if err then
	print("Error: " .. err.message)
	if err.suggestion then print("Suggestion: " .. err.suggestion) end
	if err.context and err.context.stderr then print("bq stderr: " .. tostring(err.context.stderr)) end
	return
end
return res.schema

-- Show full table metadata
local info, err = gcloud.bigquery.describe("my-project", "dataset.table")
if err then error(err.message) end
return info
]],
		},
		{
			name = "show",
			signature = "(project, table, [opts])",
			returns_contract = "core.result",
			description = "DEPRECATED: Use gcloud.bigquery.describe() instead. This is a backward compatibility alias.",
			readonly = true,
			params = {
				{
					name = "project",
					type = "string",
					optional = false,
					description = "GCP project ID (required)",
				},
				{
					name = "table",
					type = "string",
					optional = false,
					description = "Table identifier (required), e.g. 'dataset.table' or 'project:dataset.table'",
				},
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Optional parameters",
					schema = {
						schema = {
							type = "boolean",
							optional = true,
							description = "If true, include schema details. Default: false",
						},
						timeout = {
							type = "number",
							optional = true,
							description = "Command timeout in seconds. Default: 300",
						},
					},
				},
			},
			returns_typed = {
				{
					name = "result",
					type = "TableInfo",
					description = "Table metadata or schema-only output",
				},
				{
					name = "err",
					type = "core.error|nil",
					description = "Structured error",
				},
			},
			examples = [[
-- Prefer using gcloud.bigquery.describe() instead
local res, err = gcloud.bigquery.show("my-project", "dataset.table", {schema = true})
if err then error(err.message) end
return res
]],
		},
	},
	types = {
		QueryRow = {
			description = "BigQuery result row with dynamic columns",
			shape = "{[column_name]:any, ...}"
		},
		DryRunResult = {
			description = "Dry-run validation result with cost estimation",
			shape = "{totalBytesProcessed:string, cacheHit:boolean, schema:table, ...}"
		},
		TableInfo = {
			description = "BigQuery table/view metadata returned by bq show",
			shape = "{id?:string, type?:string, numBytes?:string, numRows?:string, schema?:{fields:Field[]}, ...}"
		},
		Field = {
			description = "BigQuery schema field",
			shape = "{name:string, type:string, mode?:string, description?:string, fields?:Field[]}"
		}
	}
}
