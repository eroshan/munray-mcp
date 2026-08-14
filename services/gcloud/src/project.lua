-- gcloud.project.list implementation
local STORE_TYPE = "cache"

local function cache_key_for_project_list()
	-- Cache key must not depend on input; we cache the full, unfiltered project list
	-- and apply local pattern matching afterwards.
	return "gcloud.project.list"
end

local function err_invalid_field(name, message, value)
	return {
		code = "INVALID_FIELD_VALUE",
		message = message,
		context = {
			field = name,
			value = value,
		},
		recoverable = false,
	}
end

local function validate_opts(opts)
	if opts == nil then
		return {}, nil
	end
	if type(opts) ~= "table" then
		return nil, {
			code = "INVALID_OPTIONS",
			message = "opts must be a table",
			context = { opts_type = type(opts) },
			recoverable = false,
		}
	end

	if opts.project_pattern ~= nil then
		if type(opts.project_pattern) ~= "string" then
			return nil, err_invalid_field("project_pattern", "project_pattern must be a string", opts.project_pattern)
		end
		if opts.project_pattern ~= "" then
			local ok, pattern_err = pcall(string.match, "", opts.project_pattern)
			if not ok then
				return nil, err_invalid_field(
					"project_pattern",
					"project_pattern must be a valid Lua pattern: " .. tostring(pattern_err),
					opts.project_pattern
				)
			end
		end
	end
	if opts.force_gcp_read ~= nil and type(opts.force_gcp_read) ~= "boolean" then
		return nil, err_invalid_field("force_gcp_read", "force_gcp_read must be a boolean", opts.force_gcp_read)
	end

	return opts, nil
end

local function project_search_text(project)
	return table.concat({
		tostring(project.projectId or ""),
		tostring(project.name or ""),
		tostring(project.projectNumber or ""),
		tostring(project.lifecycleState or ""),
		tostring(project.createTime or ""),
	}, " ")
end

local function matches_project_pattern(project, project_pattern)
	if project_pattern == nil or project_pattern == "" then
		return true
	end
	return string.match(project_search_text(project), project_pattern) ~= nil
end

local function wrap_project_cli_error(raw_err, args)
	local context = { args = args }
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

	local detail_parts = {}
	if raw_err and raw_err.message then
		detail_parts[#detail_parts + 1] = raw_err.message
	end
	if context.stderr then
		detail_parts[#detail_parts + 1] = tostring(context.stderr)
	end
	if context.stdout then
		detail_parts[#detail_parts + 1] = tostring(context.stdout)
	end

	local detail_text = table.concat(detail_parts, "\n"):lower()
	if detail_text:find("gcloud auth login", 1, true)
		or detail_text:find("no credentialed accounts", 1, true)
		or detail_text:find("no active account", 1, true)
		or detail_text:find("active account selected", 1, true) then
		return nil, {
			code = "AUTH_FAILED",
			message = "gcloud authentication is required before listing projects",
			recoverable = true,
			hint = "Run gcloud auth login and verify the active account before retrying.",
			context = context,
		}
	end

	return nil, {
		code = "CLI_ERROR",
		message = "gcloud projects list failed: " .. ((raw_err and raw_err.message) or tostring(raw_err)),
		recoverable = true,
		hint = "See err.context.stderr for gcloud CLI details.",
		context = context,
	}
end

local function apply_opts(projects, opts)
	local out = {}
	for _, p in ipairs(projects or {}) do
		if matches_project_pattern(p, opts.project_pattern) then
			out[#out + 1] = p
		end
	end
	return out
end

local function project_list(opts)
	local validation_err
	opts, validation_err = validate_opts(opts)
	if validation_err then
		return nil, validation_err
	end
	local force_gcp = opts.force_gcp_read == true

	local cache_key = cache_key_for_project_list()
	if not force_gcp then
		local cached, cache_err = sys.kv.get(STORE_TYPE, cache_key)
		if cache_err then
			return nil, {
				code = "STORE_ERROR",
				message = "sys.kv.get failed: " .. (cache_err.message or tostring(cache_err)),
				context = { key = cache_key },
				recoverable = true,
			}
		end
		if cached ~= nil then
			return apply_opts(cached, opts), nil
		end
	end

	-- Build gcloud command arguments
	-- Intentionally unfiltered/unlimited so we can cache the full output.
	local args = {"projects", "list"}
	-- Add --format=json for structured output
	table.insert(args, "--format=json")

	-- Execute via sys.cli.json primitive
	local result, cli_err = sys.cli.json("gcloud", args)
	if cli_err then
		return wrap_project_cli_error(cli_err, args)
	end

	-- Persist result into store (never expires). This is best-effort: in readonly
	-- execution mode, sys.kv.put will be blocked, but we still return the live result.
	local _, put_err = sys.kv.put(STORE_TYPE, cache_key, result)
	if put_err then
		-- Non-fatal: caller still gets the live result.
		-- (If executed in guarded mode, this will succeed.)
	end

	-- Return array of projects
	return apply_opts(result, opts), nil
end
gcloud.project.list = project_list
-- Schema metadata for capabilities discovery
gcloud.project.__schema = {
	namespace = "gcloud.project",
	service = "gcloud",
	description = "Google Cloud Platform project operations. project.list reads from the cached full project list by default; set force_gcp_read = true to rescan GCP and refresh the cache.",
	functions = {
		{
			name = "list",
			signature = "([opts])",
			returns_contract = "core.result",
			description = "List GCP projects from the cached full project list by default. Set force_gcp_read = true to rescan GCP and refresh the cache; project_pattern applies local Lua-pattern matching to the cached results.",
			readonly = true,
			params = {
				{
					name = "opts",
					type = "table",
					optional = true,
					description = "Optional parameters",
					schema = {
						project_pattern = {type = "string", optional = true, description = "Lua pattern matched against projectId, name, projectNumber, lifecycleState, and createTime"},
						force_gcp_read = {type = "boolean", optional = true, description = "If true, bypass the cache, rescan GCP, and refresh the cached full project list"}
					}
				}
			},
			returns_typed = {
				{
					name = "result",
					type = "Project[]",
					description = "Array of projects"
				},
				{
					name = "err",
					type = "core.error|nil",
					description = "Structured error with code/message/context/recoverable. Codes: INVALID_OPTIONS, INVALID_FIELD_VALUE, STORE_ERROR, AUTH_FAILED, CLI_ERROR"
				}
			}
		}
	},
	types = {
		Project = { description = "GCP Project resource", shape = "{projectId?:string, name?:string, projectNumber?:string, lifecycleState?:string, createTime?:string, ...}" },
	}
}
