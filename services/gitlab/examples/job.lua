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
job_id = 789
pipeline_id = 456

-- Get job (temporary variables with 'local')
local job, get_err = gitlab.job.get(repo, job_id)
if get_err then error(get_err) end
print(job.name, job.status)

-- List pipeline jobs (iterator mode - default)
print("Iterating jobs:")
for j in gitlab.job.list(repo, pipeline_id, { per_page = 5, limit = 5 }) do
    print(j.id, j.name, j.status)
end

-- Collect jobs using helpers.collect()
print("\nCollecting jobs:")
local jobs, list_err = helpers.collect(gitlab.job.list(repo, pipeline_id, { per_page = 5 }), { limit = 5 })
if list_err then error(list_err) end
print("Collected", #jobs, "jobs")
for _, row in ipairs(jobs) do
    local j = row[1]
    print(j.id, j.name, j.status)
end

-- Get job log (reuses session vars)
local log, log_err = gitlab.job.log(repo, job_id)
if log_err then error(log_err) end
print("Log length:", #log)

-- Retry job (requires mutating mode)
local ok, retry_err = gitlab.job.retry(repo, job_id)
if retry_err then error(retry_err) end
print("Retried:", ok)

-- Download artifacts archive for a specific job id into the session VFS (allowed in read-only mode)
-- This writes a zip to a VFS path under opts.file.
local artifacts, artifacts_err = gitlab.job.artifact_download(repo, job_id, { file = "artifacts/job-" .. tostring(job_id) .. ".zip" })
if artifacts_err then error(artifacts_err) end
print("Artifacts archive (VFS):", artifacts.file, "bytes:", artifacts.bytes)

-- Expose the archive as a host-readable temp file (requires mutating mode)
local exposed, expose_err = vfs.expose({artifacts.file})
if expose_err then error(expose_err) end
print("Artifacts archive (host):", exposed.files[1].host_path)

-- Optional: extract + preview text files in the zip
local preview, preview_err = vfs.to_txt(artifacts.file)
if preview_err then error(preview_err) end
print(preview.summary)
print("Extracted to:", preview.extracted_dir)
