-- task.lua: Task management API for background execution
--
-- This module provides functions to check status, retrieve results, and wait on
-- background tasks started via _raw.cli.start_*, _raw.http.start_*, etc.
--
-- IMPORTANT: Task records are retained for ~5 minutes after completion. After this period,
-- tasks are cleaned up and async_task.* queries may return NOT_FOUND.
-- Tasks are also session-scoped: you must poll/result/wait using the same munray-mcp session
-- that created the task_id.
--
-- NOTE: This namespace is called `async_task` (not `task`) to avoid common variable
-- collisions in user code.

-- Global async_task namespace
async_task = {}

-- async_task.status(task_id) -> (status, err)
-- Returns the current status of a task.
--
-- status shape:
-- {
--   state = "running" | "completed" | "failed" | "cancelled",
--   started_at_ms = number,
--   finished_at_ms = number|nil,
-- }
function async_task.status(task_id)
  if not task_id then
    return nil, { code = "VALIDATION", message = "task_id is required", recoverable = false }
  end

  return _raw.task.status(task_id)
end

-- async_task.result(task_id, opts?) -> (result, err)
-- Retrieves the result of a completed task.
--
-- Returns:
-- - (result, nil) if task is completed
-- - (nil, {code="NOT_READY", ...}) if task is still running
-- - (nil, {code="TIMEOUT"|"CLI_ERROR"|"HTTP_ERROR"|..., ...}) if the task failed with a structured transport/runtime error
-- - (nil, {code="FAILED", ...}) if the task failed without a more specific structured error
-- - (nil, {code="CANCELLED", ...}) if task was cancelled
-- - (nil, {code="NOT_FOUND", ...}) if task doesn't exist
function async_task.result(task_id, _opts)
  if not task_id then
    return nil, { code = "VALIDATION", message = "task_id is required", recoverable = false }
  end

  -- opts reserved for future wait_ms implementation
  return _raw.task.result(task_id)
end

-- async_task.wait(task_id, timeout_ms?) -> (result, err)
-- Waits for a task to complete, polling until finished or timeout.
--
-- Args:
--   task_id: Task identifier
--   timeout_ms: Optional timeout in milliseconds (default: 295000 = 4m55s)
--
-- Returns:
-- - (result, nil) if task completed successfully
-- - (nil, {code="TIMEOUT", ...}) if wait timeout exceeded
-- - (nil, {code="TIMEOUT"|"CLI_ERROR"|"HTTP_ERROR"|..., ...}) if the task itself failed with a structured transport/runtime error
-- - (nil, {code="FAILED", ...}) if the task failed without a more specific structured error
-- - (nil, {code="CANCELLED", ...}) if task was cancelled
-- - (nil, {code="NOT_FOUND", ...}) if task doesn't exist
function async_task.wait(task_id, timeout_ms)
  if not task_id then
    return nil, { code = "VALIDATION", message = "task_id is required", recoverable = false }
  end

  timeout_ms = timeout_ms or 295000
  return _raw.task.wait(task_id, timeout_ms)
end

-- Schema for async_task API (for capabilities discovery)
async_task.__schema = {
  namespace = "async_task",
  service = "core",
  description = "Task management API for background execution",
  functions = {
    {
      path = "async_task.status",
      name = "status",
      signature = "(task_id)",
      returns_contract = "core.result",
      mutating = false,
      params = {
        { name = "task_id", type = "string", description = "Task identifier" }
      },
      returns_typed = {
        {
          name = "result",
          type = "table",
          description = "Task status with fields: state, started_at_ms, finished_at_ms"
        },
        { name = "err", type = "core.error|nil", description = "Error if operation failed" }
      },
      description = "Returns the current status of a task"
    },
    {
      path = "async_task.result",
      name = "result",
      signature = "(task_id, opts?)",
      returns_contract = "core.result",
      mutating = false,
      params = {
        { name = "task_id", type = "string", description = "Task identifier" },
        { name = "opts", type = "table", optional = true, description = "Options (reserved for future use)" }
      },
      returns_typed = {
        { name = "result", type = "any", description = "Task result if completed" },
        { name = "err", type = "core.error|nil", description = "Error if task not ready or failed" }
      },
      description = "Retrieves the result of a completed task. Returns NOT_READY while running and preserves structured task errors when available.",
      examples = [[
-- Poll until complete
local task_id = _raw.cli.start_json("gcloud", {"projects", "list", "--format=json"})
local result, err = async_task.result(task_id)
while err and err.code == "NOT_READY" do
  -- Wait and retry (in practice, make multiple tool calls)
  result, err = async_task.result(task_id)
end
if err then
  error("Task failed: " .. err.message)
end
return result
]]
    },
    {
      path = "async_task.wait",
      name = "wait",
      signature = "(task_id, timeout_ms?)",
      returns_contract = "core.result",
      mutating = false,
      params = {
        { name = "task_id", type = "string", description = "Task identifier" },
        { name = "timeout_ms", type = "number", optional = true, description = "Timeout in milliseconds (default: 295000 = 4m55s)" }
      },
      returns_typed = {
        { name = "result", type = "any", description = "Task result if completed" },
        { name = "err", type = "core.error|nil", description = "Error if wait timeout is exceeded, the task fails, or it is cancelled; structured task errors are preserved when available" }
      },
      description = "Waits for a task to complete, blocking until finished or timeout. Default timeout is 4m55s (just under task retention limit).",
      examples = [[
-- Start async operation and wait for completion
local task_id = _raw.cli.start_json("gcloud", {"projects", "list", "--format=json"})
local result, err = async_task.wait(task_id)
if err then
  if err.code == "TIMEOUT" then
    result, err = async_task.wait(task_id, 600000) -- 10 minutes
  else
    error("Task failed: " .. err.message)
  end
end
return result
]]
    }
  }
}
