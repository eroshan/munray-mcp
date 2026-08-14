-- preload/gitlab/job.lua
-- luacheck: globals vfs
-- Job functions (stateless, no object wrapping)

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()

-- Capture raw primitives at load time
local raw_blob_from_cli = sys.blob and sys.blob.from_cli or nil
local raw_blob_len = sys.blob and sys.blob.len or nil

-- Capture VFS helpers (core preload)
local vfs_ensure_parent = vfs and vfs.ensure_parent or nil
local raw_vfs_write_blob = sys.vfs and sys.vfs.write_blob or nil

gitlab.job.__schema = {
	namespace = "gitlab.job",
	service = "gitlab",
	functions = {
		{
			name = "get",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = false,
			description = "Fetch a single job by ID",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Job" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "list",
			signature = "(repo, pipeline_id, opts)",
			returns_contract = "core.iter",
			yields = "Job",
			guarded = false,
			description = "List jobs for a pipeline with optional filtering (returns iterator; use helpers.collect() to materialize to array). Supports scope (status filter), stages, name_pattern, and exclude_names options.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "pipeline_id", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options: per_page, scope (array of status strings), stages (array), name_pattern (regex), exclude_names (array)" }
			},
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "trigger_jobs",
			signature = "(repo, pipeline_id, opts)",
			returns_contract = "core.iter",
			yields = "Job",
			guarded = false,
			description = "List trigger jobs (bridge jobs) for a pipeline (returns iterator; use helpers.collect() to materialize to array). Items often include a downstream_pipeline field for the triggered pipeline.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "pipeline_id", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options: per_page, scope (array of status strings), stages (array), name_pattern (regex), exclude_names (array)" }
			},
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "log",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = false,
			description = "Fetch job log",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "string" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "retry",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = true,
			description = "Retry a failed job",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Job" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "play",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = true,
			description = "Play (trigger) a manual job",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Job" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "pipeline",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = false,
			description = "Get the parent pipeline for this job",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Pipeline" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "artifact_download",
			signature = "(repo, id, opts)",
			returns_contract = "core.result",
			guarded = false,
			description = "Download the artifacts archive for a specific job ID (GitLab Job Artifacts API) into the session VFS. Captures the binary archive as a blob (no bytes exposed to Lua) and writes it to opts.file via sys.vfs.write_blob(). Expose the resulting VFS file with vfs.expose({...}) when you need a host-readable path for agent inspection.",
			params = {
				{ name = "repo", type = "string|number", description = "Project path like 'group/project' or numeric project id (used to resolve project id)." },
				{ name = "id", type = "number", description = "Job id" },
				{ name = "opts", type = "table", optional = false, description = "Options: file (required VFS path), cwd (string), timeout (seconds), max_bytes (number), overwrite (boolean)" },
			},
			returns_typed = { { name = "result", type = "ArtifactDownloadResult" }, { name = "err", type = "core.error|nil" } },
			examples = [[
				-- Download artifacts zip into VFS
				local res, err = gitlab.job.artifact_download("group/project", 123456, { file = "artifacts/job-123456.zip" })
				if err then error(err) end

				-- Expose the archive as a host-readable temp file (guarded mode required)
				local exposed, err2 = vfs.expose({res.file})
				if err2 then error(err2) end
				return { downloaded = res, exposed = exposed.files[1] }
			]],
		},
	},
	types = {
		Job = { shape = "{id:number, name?:string, stage?:string, status?:string, web_url?:string, downstream_pipeline?:table, ...}" },
		Pipeline = { shape = "{id:number, status?:string, ref?:string, sha?:string, web_url?:string, ...}" },
		ArtifactDownloadResult = { shape = "{file:string, bytes:number, job_id:number, project_id:number}" },
	},
}

local function apply_job_filters(base_iterator, opts)
	-- Client-side filtering for stages, name_pattern, and exclude_names
	local needs_filtering = opts.stages or opts.name_pattern or opts.exclude_names

	if not needs_filtering then
		return base_iterator
	end

	return function()
		while true do
			local job, meta = base_iterator()
			if not job then
				return nil
			end

			local passes = true

			-- Filter by stages
			if passes and opts.stages and type(opts.stages) == "table" then
				local stage_match = false
				for _, stage in ipairs(opts.stages) do
					if job.stage == stage then
						stage_match = true
						break
					end
				end
				if not stage_match then
					passes = false
				end
			end

			-- Filter by name_pattern (Lua pattern matching)
			if passes and opts.name_pattern and job.name then
				if not string.match(job.name, opts.name_pattern) then
					passes = false
				end
			end

			-- Filter out excluded names
			if passes and opts.exclude_names and type(opts.exclude_names) == "table" and job.name then
				for _, excluded in ipairs(opts.exclude_names) do
					if job.name == excluded then
						passes = false
						break
					end
				end
			end

			if passes then
				return job, meta
			end
		end
	end
end

function gitlab.job.get(repo, id)
	return client.request_json("GET", repo, "jobs/" .. id, nil, nil)
end

function gitlab.job.list(repo, pipeline_id, opts)
	opts = opts or {}
	local query = {}

	-- Server-side filtering: scope (job status)
	-- GitLab API supports scope[] parameter for status filtering
	if opts.scope and type(opts.scope) == "table" then
		-- Note: the key name intentionally includes [] so the query builder emits repeated params.
		query["scope[]"] = opts.scope
	end

	local base_iterator = client.list(repo, "pipelines/" .. pipeline_id .. "/jobs", query, opts)
	return apply_job_filters(base_iterator, opts)
end

function gitlab.job.trigger_jobs(repo, pipeline_id, opts)
	opts = opts or {}
	local query = {}

	-- Server-side filtering: scope (job status)
	if opts.scope and type(opts.scope) == "table" then
		query["scope[]"] = opts.scope
	end

	-- Implementation detail: GitLab exposes trigger/bridge jobs for a pipeline.
	-- We keep the Lua API focused on the domain concept (trigger jobs) rather than raw endpoint naming.
	local base_iterator = client.list(repo, "pipelines/" .. pipeline_id .. "/bridges", query, opts)
	return apply_job_filters(base_iterator, opts)
end

function gitlab.job.log(repo, id)
	-- Use generic API to get job trace as plain text
	return client.request_text("GET", repo, "jobs/" .. id .. "/trace", nil)
end

function gitlab.job.retry(repo, id)
	-- POST to retry endpoint, then refresh to get updated job
	local _result, err = client.request_json("POST", repo, "jobs/" .. id .. "/retry", nil, {})
	if err then return nil, err end
	-- Refresh pattern: get updated job after mutation
	return client.request_json("GET", repo, "jobs/" .. id, nil, nil)
end

function gitlab.job.play(repo, id)
	-- POST to play endpoint to trigger manual job, then refresh to get updated job
	local _result, err = client.request_json("POST", repo, "jobs/" .. id .. "/play", nil, {})
	if err then return nil, err end
	-- Refresh pattern: get updated job after mutation
	return client.request_json("GET", repo, "jobs/" .. id, nil, nil)
end

-- Download job artifacts archive by job id into the session VFS (non-guarded by policy).
-- API: GET /projects/:id/jobs/:job_id/artifacts
function gitlab.job.artifact_download(repo, id, opts)
	if type(opts) ~= "table" then
		return nil, {
			code = "VALIDATION",
			message = "gitlab.job.artifact_download: opts table is required (opts.file is required)",
			context = { repo = repo, job_id = id },
			recoverable = false,
		}
	end

	if raw_blob_from_cli == nil or raw_blob_len == nil then
		return nil, {
			code = "NOT_AVAILABLE",
			message = "gitlab.job.artifact_download: blob primitives not available (requires munray-mcp core with sys.blob.*)",
			recoverable = false,
		}
	end

	if vfs_ensure_parent == nil or raw_vfs_write_blob == nil then
		return nil, {
			code = "NOT_AVAILABLE",
			message = "gitlab.job.artifact_download: VFS helpers not available (requires munray-mcp core with sys.vfs.* + vfs.ensure_parent)",
			recoverable = false,
		}
	end

	local out_file = opts.file
	if out_file == nil or out_file == "" then
		return nil, {
			code = "VALIDATION",
			message = "gitlab.job.artifact_download: opts.file is required (VFS path)",
			context = { repo = repo, job_id = id },
			recoverable = false,
		}
	end

	local project_id, id_err = client.resolve_project_id(repo)
	if id_err then return nil, id_err end

	local endpoint = client.project_path(project_id, "jobs/" .. tostring(id) .. "/artifacts")
	local args = {
		"api",
		endpoint,
		"-H",
		"Accept: application/octet-stream",
	}

	local cli_opts = {}
	if opts.cwd ~= nil then cli_opts.cwd = opts.cwd end
	if opts.timeout ~= nil then cli_opts.timeout = opts.timeout end
	if opts.max_bytes ~= nil then cli_opts.max_bytes = opts.max_bytes end

	local blob, err = raw_blob_from_cli("glab", args, cli_opts)
	if err then return nil, err end

	local _ok, parent_err = vfs_ensure_parent(out_file)
	if parent_err then return nil, parent_err end

	local overwrite = true
	if opts.overwrite ~= nil then
		overwrite = opts.overwrite ~= false
	end

	local _info, write_err = raw_vfs_write_blob(out_file, blob, { overwrite = overwrite })
	if write_err then return nil, write_err end

	local n, len_err = raw_blob_len(blob)
	if len_err then return nil, len_err end

	return {
		file = out_file,
		bytes = n,
		job_id = id,
		project_id = project_id,
	}, nil
end

-- Get parent pipeline for this job
function gitlab.job.pipeline(repo, id)
	local job, err = gitlab.job.get(repo, id)
	if err then return nil, err end

	-- Job should have pipeline.id field
	if job.pipeline and job.pipeline.id then
		return gitlab.pipeline.get(repo, job.pipeline.id)
	end

	return nil, {
		code = "RESOURCE_NOT_FOUND",
		message = "Job #" .. id .. " does not have an associated pipeline",
		recoverable = false,
		suggestion = "Verify that the job exists and has a valid pipeline reference"
	}
end
