-- GCloud Logs Examples - Async Task-Based Pattern
-- All examples use core async_task.* helpers.
-- Prefer async_task.wait(task_id, timeout_ms?) over manual polling.

-- Example 1: Basic async usage - recent errors from last 2 hours
print("\n=== Example 1: Basic async usage ===")
local task_id, err = gcloud.logs.get(
	"my-project-id",
	"resource.type=gce_instance AND severity>=ERROR",
	{freshness = "2h", limit = 100}
)
if err then
	print("Error starting task:", err.message)
	if err.suggestion then print("Suggestion:", err.suggestion) end
else
	print("Task started:", task_id)
	local logs, wait_err = async_task.wait(task_id)
	if wait_err then
		print("Error waiting for task:", wait_err.message)
	else
		print("Found", #logs, "error logs")
		for i, entry in ipairs(logs) do
			if i <= 3 then  -- Show first 3
				print(entry.timestamp, entry.severity, entry.textPayload or entry.jsonPayload)
			end
		end
	end
end

-- Example 2: Specific time range (freshness ignored)
print("\n=== Example 2: Specific time range ===")
local task_id2, err2 = gcloud.logs.get(
	"my-project-id",
	'timestamp>="2024-01-01T00:00:00Z" AND timestamp<="2024-01-31T23:59:59Z" AND severity=ERROR',
	{limit = 50}
)
if err2 then
	print("Error:", err2.message)
else
	local logs2, wait_err2 = async_task.wait(task_id2)
	if wait_err2 then
		print("Error:", wait_err2.message)
	elseif logs2 then
		print("Found", #logs2, "error logs in January 2024")
	end
end

-- Example 3: All recent logs with default freshness (1d)
print("\n=== Example 3: Default freshness (1d) - no filter ===")
local task_id3, err3 = gcloud.logs.get(
	"my-project-id",
	nil,  -- No filter
	{limit = 10}
)
if err3 then
	print("Error:", err3.message)
else
	local recent_logs, wait_err3 = async_task.wait(task_id3)
	if wait_err3 then
		print("Error:", wait_err3.message)
	elseif recent_logs then
		print("Found", #recent_logs, "recent logs (last 24 hours)")
	end
end

-- Example 4: Filter by resource and severity
print("\n=== Example 4: Kubernetes critical logs ===")
local task_id4, err4 = gcloud.logs.get(
	"production-project",
	"resource.type=k8s_container AND severity=CRITICAL",
	{freshness = "24h"}
)
if err4 then
	print("Error:", err4.message)
else
	local critical_logs, wait_err4 = async_task.wait(task_id4)
	if wait_err4 then
		print("Error:", wait_err4.message)
	elseif critical_logs then
		print("Found", #critical_logs, "critical container logs")
	end
end

-- Example 5: Error handling - invalid filter
print("\n=== Example 5: Error handling - invalid filter ===")
local task_id5, err5 = gcloud.logs.get(
	"my-project-id",
	"invalid filter syntax"
)
if err5 then
	-- Error starting the task
	if err5.code == "API_ERROR" then
		print("API error starting task:", err5.message)
	elseif err5.code == "MISSING_REQUIRED_FIELD" then
		print("Project ID is required")
	else
		print("Unexpected error:", err5.message)
	end
else
	-- Task started, but might fail during execution
	local logs5, wait_err5 = async_task.wait(task_id5)
	if wait_err5 then
		print("Task error:", wait_err5.message)
	elseif logs5 then
		print("Found", #logs5, "logs")
	end
end

-- Example 6: Empty results handling
print("\n=== Example 6: Empty results ===")
local task_id6, err6 = gcloud.logs.get(
	"my-project-id",
	"severity=EMERGENCY",  -- Might return no results
	{freshness = "1h"}
)
if err6 then
	print("Error:", err6.message)
else
	local no_logs, wait_err6 = async_task.wait(task_id6)
	if wait_err6 then
		print("Error:", wait_err6.message)
	elseif #no_logs == 0 then
		print("No emergency logs found in the last hour")
	else
		print("Found", #no_logs, "emergency logs")
	end
end

-- Example 7: Query logs by log name with structured payload
print("\n=== Example 7: Structured logs by log name ===")
local task_id7, err7 = gcloud.logs.get(
	"my-project-id",
	'logName="projects/my-project-id/logs/my-app-log"',
	{freshness = "6h", limit = 200}
)
if err7 then
	print("Error:", err7.message)
else
	local app_logs, wait_err7 = async_task.wait(task_id7)
	if wait_err7 then
		print("Error:", wait_err7.message)
	elseif app_logs then
		print("Found", #app_logs, "application logs")
		for i, entry in ipairs(app_logs) do
			if i <= 3 then  -- Show first 3
				if entry.jsonPayload then
					print("Structured log:", entry.jsonPayload.message or "no message field")
				elseif entry.textPayload then
					print("Text log:", entry.textPayload)
				end
			end
		end
	end
end

-- Example 8: Missing project error
print("\n=== Example 8: Missing project error ===")
local task_id8, err8 = gcloud.logs.get(
	nil,  -- Missing project
	"severity=ERROR"
)
if err8 then
	print("Error code:", err8.code)  -- Will be "MISSING_REQUIRED_FIELD"
	print("Error message:", err8.message)
	if err8.suggestion then print("Suggestion:", err8.suggestion) end
else
	print("Unexpected: task should not start without project")
end

-- Example 9: Task status check
print("\n=== Example 9: Task status check ===")
local task_id9, err9 = gcloud.logs.get(
	"my-project-id",
	"severity>=INFO",
	{freshness = "7d", limit = 10000}  -- Large query
)
if err9 then
	print("Error:", err9.message)
else
	print("Task started:", task_id9)
	local status, status_err = async_task.status(task_id9)
	if status_err then
		print("Error checking status:", status_err.message)
	elseif status then
		print("Current state:", status.state)
	else
		print("No status available")
	end
end

-- Example 10: Polling timeout handling
print("\n=== Example 10: Polling timeout ===")
local task_id10, err10 = gcloud.logs.get(
	"my-project-id",
	"severity>=DEBUG",
	{freshness = "30d", limit = 50000}  -- Very large query
)
if err10 then
	print("Error:", err10.message)
else
	-- Intentionally short timeout to demonstrate TIMEOUT handling
	local logs10, wait_err10 = async_task.wait(task_id10, 2000)
	if wait_err10 and wait_err10.code == "TIMEOUT" then
		print("Timed out waiting; task may still be running.")
		print("Task ID for later retrieval:", task_id10)
		-- You can retry with a longer timeout:
		-- logs10, wait_err10 = async_task.wait(task_id10, 600000)
	elseif wait_err10 then
		print("Error:", wait_err10.message)
	elseif logs10 then
		print("Found", #logs10, "logs (completed quickly)")
	end
end

print("\n=== Examples complete ===")
