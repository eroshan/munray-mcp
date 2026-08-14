-- task.lua: Task management API for background execution
--
-- This module provides functions to check status, retrieve results, and wait on
-- background tasks started via sys.cli.start_*, sys.http.start_*, etc.
--
-- Task records are retained for the lifetime of their runtime. Tasks are
-- session-scoped: you must poll/result/wait using the same munray-mcp session
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

  return sys.task.status(task_id)
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
  return sys.task.result(task_id)
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
  if type(timeout_ms) ~= "number" or timeout_ms < 0 or timeout_ms == math.huge or timeout_ms ~= math.floor(timeout_ms) then
    return nil, { code = "VALIDATION", message = "timeout_ms must be a non-negative integer", recoverable = false }
  end
  return sys.task.wait(task_id, timeout_ms)
end

-- async_task.cancel(task_id) -> (cancelled, err)
-- Requests cancellation of a running task. CLI tasks observe this request while
-- polling their child process; transport tasks may only update visible state.
function async_task.cancel(task_id)
  if not task_id then
    return nil, { code = "VALIDATION", message = "task_id is required", recoverable = false }
  end

  return sys.task.cancel(task_id)
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
      readonly = true,
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
      readonly = true,
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
local task_id = sys.cli.start_json("gcloud", {"projects", "list", "--format=json"})
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
      readonly = true,
      params = {
        { name = "task_id", type = "string", description = "Task identifier" },
        { name = "timeout_ms", type = "number", optional = true, description = "Timeout in milliseconds (default: 295000 = 4m55s)" }
      },
      returns_typed = {
        { name = "result", type = "any", description = "Task result if completed" },
        { name = "err", type = "core.error|nil", description = "Error if wait timeout is exceeded, the task fails, or it is cancelled; structured task errors are preserved when available" }
      },
      description = "Waits for a task to complete, blocking until finished or timeout.",
      examples = [[
-- Start async operation and wait for completion
local task_id = sys.cli.start_json("gcloud", {"projects", "list", "--format=json"})
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
    },
    {
      path = "async_task.cancel",
      name = "cancel",
      signature = "(task_id)",
      returns_contract = "core.result",
      guarded = true,
      params = {
        { name = "task_id", type = "string", description = "Task identifier" }
      },
      returns_typed = {
        { name = "result", type = "boolean", description = "Whether cancellation was requested" },
        { name = "err", type = "core.error|nil", description = "Error if the task does not exist" }
      },
      description = "Request cancellation of a running task"
    }
  }
}
