-- gcloud.logs.get implementation
-- Retrieve log entries from Cloud Logging (async task-based)

-- Capture raw primitives as upvalues (security best practice)
local raw_cli_start_json = _raw.cli.start_json

local LOGS_GET_TIMEOUT_SECONDS = 300

local function logs_get(project, filter, opts)
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

	-- filter can be nil or empty string (will retrieve all logs)
	if filter ~= nil and type(filter) ~= "string" then
		return nil, {
			code = "INVALID_FIELD_VALUE",
			message = "filter parameter must be a string if provided",
			recoverable = false,
			suggestion = "Provide a valid Logging Query Language expression or omit for all logs",
			context = { filter = filter }
		}
	end

	-- Normalize opts
	opts = opts or {}

	-- Build gcloud command arguments
	local args = {"logging", "read"}

	-- Add filter as positional argument if provided
	if filter and filter ~= "" then
		table.insert(args, filter)
	end

	-- Add project flag (required)
	table.insert(args, "--project=" .. project)

	-- Handle freshness (conditional logic)
	-- If filter contains timestamp conditions, ignore freshness
	if filter and filter:find("timestamp") then
		-- Skip freshness entirely (prefer filter timestamp)
		-- (no-op: freshness is ignored when filter has explicit timestamp)
	else
		-- Add freshness flag
		if opts.freshness and opts.freshness ~= "" then
			table.insert(args, "--freshness=" .. opts.freshness)
		else
			-- Default freshness is 1d
			table.insert(args, "--freshness=1d")
		end
	end

	-- Add limit if provided
	if opts.limit and opts.limit > 0 then
		table.insert(args, "--limit=" .. tostring(opts.limit))
	end

	-- Add JSON output format
	table.insert(args, "--format=json")

	-- Execute via _raw.cli.start_json primitive (async task-based)
	local task_id, err = raw_cli_start_json("gcloud", args, { timeout = LOGS_GET_TIMEOUT_SECONDS })
	if err then
		return nil, {
			code = "API_ERROR",
			message = "Failed to start gcloud logging read task: " .. (err.message or tostring(err)),
			recoverable = true,
			suggestion = "Check project permissions and filter syntax. Verify Cloud Logging API is enabled.",
			context = { args = args, project = project }
		}
	end

	-- Return task_id for async polling
	return task_id, nil
end

gcloud.logs.get = logs_get

-- Schema metadata for capabilities discovery
gcloud.logs.__schema = {
	namespace = "gcloud.logs",
	service = "gcloud",
	description = "Google Cloud Logging operations",
	functions = {
		{
			name = "get",
			path = "gcloud.logs.get",
			signature = "(project, filter, [opts])",
			returns_contract = "core.async.result",
			async = {
				kind = "task",
				handle = "task_id",
				sequential_calls = true,
				usage = "Returns a task_id handle. Use async_task.status(task_id) to poll, async_task.result(task_id) to fetch the result, or async_task.wait(task_id) to block until ready.",
			},
			description = "Start async retrieval of log entries from Cloud Logging. Returns a task_id string for later polling. Use async_task.wait(), async_task.status(), and async_task.result() to retrieve logs. The final result is a plain Lua array of LogEntry.",
			mutating = false,
			params = {
				{
					name = "project",
					type = "string",
					optional = false,
					description = "Project ID to query (required)"
				},
				{
					name = "filter",
					type = "string",
					optional = true,
					description = "Logging Query Language expression (e.g., 'resource.type=gce_instance AND severity>=ERROR'). Omit to retrieve all logs."
				},
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Optional parameters for log retrieval",
					schema = {
						freshness = {
							type = "string",
							optional = true,
							description = "Duration for recent logs (e.g., '2h', '30m', '7d'). Default: '1d'. Ignored if filter contains timestamp conditions."
						},
						limit = {
							type = "number",
							optional = true,
							description = "Maximum number of log entries to return"
						}
					}
				}
			},
			returns_typed = {
				{
					name = "task_id",
					type = "string",
					description = "Task ID string for background log retrieval. Poll with async_task.status(task_id), retrieve results with async_task.result(task_id), or block with async_task.wait(task_id)."
				},
				{
					name = "err",
					type = "core.error|nil",
					description = "Structured error: {code, message, recoverable, suggestion, context}. Codes: MISSING_REQUIRED_FIELD, INVALID_FIELD_VALUE, API_ERROR"
				}
			},
			examples = [[
local task_id, err = gcloud.logs.get(
  "my-project-id",
  "resource.type=gce_instance AND severity>=ERROR",
  {freshness = "2h", limit = 100}
)
if err then
	print("Error: " .. err.message)
	if err.suggestion then print("Suggestion: " .. err.suggestion) end
	return
end

-- Wait for completion (default timeout: 4m55s)
local logs, result_err = async_task.wait(task_id)
if result_err then error(result_err.message) end

-- logs is a plain Lua array
return { count = #logs, first = logs[1] }
			]]
		}
	},
	types = {
		LogEntry = { description = "GCP Cloud Logging entry", shape = "{timestamp?:string, severity?:string, logName?:string, resource?:table, textPayload?:string, jsonPayload?:table, protoPayload?:table, insertId?:string, labels?:table, httpRequest?:table, operation?:table, trace?:string, spanId?:string, ...}" },
	}
}
