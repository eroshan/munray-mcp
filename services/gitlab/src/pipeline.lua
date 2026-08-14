-- preload/gitlab/pipeline.lua
-- Pipeline API - stateless functions using generic API primitives

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()

gitlab.pipeline.__schema = {
	namespace = "gitlab.pipeline",
	service = "gitlab",
	functions = {
		{
			name = "get",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = false,
			description = "Fetch a single pipeline by ID",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Pipeline" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "list",
			signature = "(repo, opts)",
			returns_contract = "core.iter",
			yields = "Pipeline",
			guarded = false,
			description = "List pipelines for a repository (returns iterator; use helpers.collect() to materialize to array)",
			params = { { name = "repo", type = "string|number" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "cancel",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = true,
			description = "Cancel a pipeline by ID",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Pipeline" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "retry",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = true,
			description = "Retry a pipeline by ID",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "Pipeline" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "create",
			signature = "(repo, data)",
			returns_contract = "core.result",
			guarded = true,
			description = "Create/trigger a new pipeline on a branch or tag",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "data", type = "table", description = "Data: ref (required), variables (array of {key, value, variable_type}), inputs (hash of key-value pairs)" }
			},
			returns_typed = { { name = "result", type = "Pipeline" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "jobs",
			signature = "(repo, pipeline_id, opts)",
			returns_contract = "core.iter",
			yields = "Job",
			guarded = false,
			description = "List jobs for a pipeline with optional filtering (convenience wrapper for gitlab.job.list). Supports scope (status filter), stages, name_pattern, and exclude_names options.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "pipeline_id", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options: per_page, scope (array), stages (array), name_pattern (regex), exclude_names (array)" }
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" }
			},
		},
		{
			name = "trigger_jobs",
			signature = "(repo, pipeline_id, opts)",
			returns_contract = "core.iter",
			yields = "Job",
			guarded = false,
			description = "List trigger jobs (bridge jobs) for a pipeline (convenience wrapper for gitlab.job.trigger_jobs). These items often include downstream_pipeline for the triggered pipeline.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "pipeline_id", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options: per_page, scope (array), stages (array), name_pattern (regex), exclude_names (array)" }
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" }
			},
		},
		{
			name = "downstream_pipelines",
			signature = "(repo, pipeline_id, opts)",
			returns_contract = "core.iter",
			yields = "Pipeline",
			guarded = false,
			description = "List downstream pipelines triggered by a pipeline. Returns iterator of downstream_pipeline objects extracted from trigger jobs.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "pipeline_id", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options forwarded to trigger_jobs: per_page, scope (array), stages (array), name_pattern (regex), exclude_names (array)" }
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" }
			},
		},
		{
			name = "merge_request",
			signature = "(repo, id)",
			returns_contract = "core.result",
			guarded = false,
			description = "Get the parent merge request that created this pipeline (returns nil if not from an MR)",
			params = { { name = "repo", type = "string|number" }, { name = "id", type = "number" } },
			returns_typed = { { name = "result", type = "MergeRequest|nil" }, { name = "err", type = "core.error|nil" } },
		},
	},
	types = {
		Pipeline = { shape = "{id:number, status?:string, ref?:string, sha?:string, web_url?:string, ...}" },
		Job = { shape = "{id:number, name?:string, stage?:string, status?:string, web_url?:string, downstream_pipeline?:table, ...}" },
		MergeRequest = { shape = "{id:number, iid:number, title:string, state?:string, web_url?:string, author?:table, ...}" },
	},
}

function gitlab.pipeline.get(repo, id)
	return client.request_json("GET", repo, "pipelines/" .. id, nil, nil)
end

function gitlab.pipeline.list(repo, opts)
	opts = opts or {}

	-- Build query parameters
	local query = {}
	if opts.ref ~= nil then
		query.ref = opts.ref
	end
	if opts.status ~= nil then
		query.status = opts.status
	end
	if opts.order_by ~= nil then
		query.order_by = opts.order_by
	end
	if opts.sort ~= nil then
		query.sort = opts.sort
	end

	return client.list(repo, "pipelines", query, opts)
end

function gitlab.pipeline.cancel(repo, id)
	local _result, err = client.request_json("POST", repo, "pipelines/" .. id .. "/cancel", nil, {})
	if err then return nil, err end
	-- Refresh pattern: fetch updated pipeline state
	return client.request_json("GET", repo, "pipelines/" .. id, nil, nil)
end

function gitlab.pipeline.retry(repo, id)
	local _result, err = client.request_json("POST", repo, "pipelines/" .. id .. "/retry", nil, {})
	if err then return nil, err end
	-- Refresh pattern: fetch updated pipeline state
	return client.request_json("GET", repo, "pipelines/" .. id, nil, nil)
end

-- Convenience function to get jobs for a pipeline
function gitlab.pipeline.jobs(repo, pipeline_id, opts)
	return gitlab.job.list(repo, pipeline_id, opts)
end

-- Convenience function to get trigger (bridge) jobs for a pipeline
function gitlab.pipeline.trigger_jobs(repo, pipeline_id, opts)
	return gitlab.job.trigger_jobs(repo, pipeline_id, opts)
end

-- Convenience iterator of downstream pipelines triggered by a pipeline.
function gitlab.pipeline.downstream_pipelines(repo, pipeline_id, opts)
	opts = opts or {}
	local base_iterator = gitlab.job.trigger_jobs(repo, pipeline_id, opts)

	return function()
		while true do
			local job, meta = base_iterator()
			if not job then
				return nil
			end
			if job.downstream_pipeline ~= nil then
				return job.downstream_pipeline, meta
			end
		end
	end
end

-- Create/trigger a new pipeline
function gitlab.pipeline.create(repo, data)
	-- Build request body
	local body = {
		ref = data.ref
	}

	-- Add variables if provided
	if data.variables and type(data.variables) == "table" then
		-- Variables need to be sent as an array of {key, value, variable_type} objects
		-- We'll encode them as form data fields
		for _, var in ipairs(data.variables) do
			if var.key then
				body["variables[" .. var.key .. "][value]"] = var.value
				-- Default to env_var if variable_type is not specified
				local var_type = var.variable_type or "env_var"
				body["variables[" .. var.key .. "][variable_type]"] = var_type
			end
		end
	end

	-- Add inputs if provided (GitLab 18.1+)
	if data.inputs and type(data.inputs) == "table" then
		for key, value in pairs(data.inputs) do
			-- Inputs are sent as a nested hash
			body["inputs[" .. key .. "]"] = tostring(value)
		end
	end

	-- Create pipeline using POST
	local result, err = client.request_json("POST", repo, "pipeline", nil, body)
	if err then return nil, err end

	-- Return the created pipeline (GitLab returns full pipeline object on creation)
	return result, nil
end

-- Get parent MR that created this pipeline (if from an MR pipeline)
function gitlab.pipeline.merge_request(repo, id)
	local pipeline, err = gitlab.pipeline.get(repo, id)
	if err then return nil, err end

	-- If pipeline has merge_request field, fetch the MR
	if pipeline.merge_request and pipeline.merge_request.iid then
		return gitlab.mr.get(repo, pipeline.merge_request.iid)
	end

	-- Pipeline not from an MR
	return nil, nil
end
