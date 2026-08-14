-- ============================================================================
-- Variable Scoping Best Practices
-- ============================================================================
-- SESSION VARIABLES (persist across calls): repo = "value"
-- TEMPORARY VARIABLES (one-time use): local result, err = func()
--
-- Common mistake: Using 'local' for values you want to reuse later
-- ============================================================================

-- Session-persisted configuration (no 'local')
repo = "group/project"
pipeline_id = 456

-- Get pipeline (temporary variables with 'local')
local pipeline, get_err = gitlab.pipeline.get(repo, pipeline_id)
if get_err then error(get_err) end
print(pipeline.status, pipeline.ref)

-- List pipelines with iterator (memory-efficient, auto-paginating)
for p in gitlab.pipeline.list(repo, { ref = "main", status = "running", per_page = 5 }) do
    print(p.id, p.status)
end

-- Collect pipelines into array with limit
local pipelines, list_err = helpers.collect(gitlab.pipeline.list(repo, { ref = "main", status = "running" }), { limit = 5 })
if list_err then error(list_err) end
print("Found", #pipelines, "pipelines")
for _, row in ipairs(pipelines) do
    local p = row[1]
    print(p.id, p.status)
end

-- Collect with max_pages to avoid fetching too much data
local recent, recent_err = helpers.collect(gitlab.pipeline.list(repo, { order_by = "id", sort = "desc" }), { max_pages = 3 })
if recent_err then error(recent_err) end
print("Collected", #recent, "recent pipelines")

-- Cancel pipeline (requires guarded mode, reuses session vars)
local ok, cancel_err = gitlab.pipeline.cancel(repo, pipeline_id)
if cancel_err then error(cancel_err) end
print("Cancelled:", ok)

-- Retry pipeline (requires guarded mode, reuses session vars)
local retried_pipeline, retry_err = gitlab.pipeline.retry(repo, pipeline_id)
if retry_err then error(retry_err) end
print("Retried:", retried_pipeline.id)

-- Get jobs for a pipeline (iterator)
for job in gitlab.pipeline.jobs(repo, pipeline_id) do
    print(job.name, job.status)
end

-- Get trigger jobs (bridge jobs) for a pipeline (iterator)
for j in gitlab.pipeline.trigger_jobs(repo, pipeline_id, { per_page = 5, limit = 5 }) do
  print("trigger job:", j.id, j.name, j.status)
  if j.downstream_pipeline then
    print("  downstream pipeline:", j.downstream_pipeline.id, j.downstream_pipeline.status, j.downstream_pipeline.web_url)
  end
end

-- Iterate downstream pipelines directly
for p in gitlab.pipeline.downstream_pipelines(repo, pipeline_id, { per_page = 5, limit = 5 }) do
  print("downstream:", p.id, p.status, p.web_url)
end

-- ============================================================================
-- Create/Trigger Pipelines
-- ============================================================================

-- Create a basic pipeline (requires guarded mode)
local new_pipeline, create_err = gitlab.pipeline.create(repo, {
    ref = "master"
})
if create_err then error(create_err) end
print("Created pipeline:", new_pipeline.id, new_pipeline.web_url, new_pipeline.status)

-- Create pipeline with variables (requires guarded mode)
local pipeline_with_vars, vars_err = gitlab.pipeline.create(repo, {
  ref = "develop",
  variables = {
    {key = "DEPLOY_ENV", value = "staging"},
    {key = "DEBUG_MODE", value = "true"},
    {key = "VERSION", value = "1.2.3"}
  }
})
if vars_err then error(vars_err) end
print("Pipeline with variables:", pipeline_with_vars.id, pipeline_with_vars.web_url)

-- Create pipeline with inputs (GitLab 18.1+, requires guarded mode)
local pipeline_with_inputs, inputs_err = gitlab.pipeline.create(repo, {
  ref = "main",
  inputs = {
    environment = "production",
    scan_security = false,
    level = 3
  }
})
if inputs_err then error(inputs_err) end
print("Pipeline with inputs:", pipeline_with_inputs.id, pipeline_with_inputs.web_url)

-- Session-persisted pattern: store full pipeline, return minimal context
new_pipeline_ref = "feature-branch"
new_pipeline_obj, err = gitlab.pipeline.create(repo, {
  ref = new_pipeline_ref,
  variables = {
    {key = "ENV", value = "test"}
  }
})
if err then error(err) end

-- ============================================================================
-- Bidirectional Navigation: Pipeline <-> MR
-- ============================================================================

-- Get parent MR for a pipeline (if pipeline was created from an MR)
local parent_mr, mr_err = gitlab.pipeline.merge_request(repo, pipeline_id)
if mr_err then
  error(mr_err)
elseif parent_mr then
  print("Pipeline created from MR:", parent_mr.iid, parent_mr.title)
else
  print("Pipeline not from an MR")
end

-- Return minimal context to AI (full object still available in session)
return {
  id = new_pipeline_obj.id,
  status = new_pipeline_obj.status,
  web_url = new_pipeline_obj.web_url
}
