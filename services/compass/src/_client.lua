-- Internal Compass GraphQL client
-- luacheck: globals compass _compass_client

local raw_graphql_request = _raw.graphql.request
local raw_graphql_list = _raw.graphql.list

_compass_client = {}
local client = _compass_client

local graphql_path = "/gateway/api/graphql"
local cloud_id_query = [[query CompassCloudId($hostName: String!) {
	tenantContexts(hostNames: [$hostName]) {
		cloudId
	}
}]]

local function trim(value)
	if type(value) ~= "string" then
		return value
	end
	return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function has_value(value)
	return type(value) == "string" and value ~= ""
end

local function validation_err(message, context)
	return {
		code = "VALIDATION_FAILED",
		message = message,
		context = context or {},
		recoverable = false,
	}
end

client.validation_err = validation_err

local function missing_field_err(field_name)
	return {
		code = "MISSING_REQUIRED_FIELD",
		message = "Required field '" .. tostring(field_name) .. "' is missing",
		context = { field = field_name },
		recoverable = false,
	}
end

client.missing_field_err = missing_field_err

local function clone_table(input, seen)
	if type(input) ~= "table" then
		return input
	end

	seen = seen or {}
	if seen[input] ~= nil then
		return seen[input]
	end

	local out = {}
	seen[input] = out
	for k, v in pairs(input) do
		out[clone_table(k, seen)] = clone_table(v, seen)
	end
	return out
end

local function enrich_err(err, extra)
	if type(err) ~= "table" then
		return err
	end

	err.context = err.context or {}
	for k, v in pairs(extra or {}) do
		if err.context[k] == nil then
			err.context[k] = v
		end
	end

	return err
end

function client.normalize_base_url(base_url)
	base_url = trim(base_url)
	if type(base_url) ~= "string" or base_url == "" then
		return base_url
	end

	return (base_url:gsub("/+$", ""))
end

function client.validate_base_url(base_url)
	if type(base_url) ~= "string" or base_url == "" then
		return false, validation_err("Either COMPASS_BASE_URL or JIRA_BASE_URL must be set", { field = "COMPASS_BASE_URL|JIRA_BASE_URL" })
	end

	if base_url:match("/gateway/api/graphql/?$") then
		return false, validation_err("Compass base URL must be the tenant root URL without /gateway/api/graphql", { base_url = base_url })
	end

	if not base_url:match("^https?://[^/]+$") then
		return false, validation_err("Compass base URL must be a host root URL like https://example.atlassian.net", { base_url = base_url })
	end

	return true, nil
end

function client.extract_host_name(base_url)
	if type(base_url) ~= "string" then
		return nil
	end
	return base_url:match("^https?://([^/]+)$")
end

local function ensure_status(checks, key)
	if type(checks[key]) ~= "table" then
		checks[key] = {}
	end
	return checks[key]
end

function client.get_config()
	if compass._config then
		return compass._config
	end

	local compass_base_url = client.normalize_base_url(os.getenv("COMPASS_BASE_URL"))
	local jira_base_url = client.normalize_base_url(os.getenv("JIRA_BASE_URL"))
	local compass_email = trim(os.getenv("COMPASS_EMAIL"))
	local jira_email = trim(os.getenv("JIRA_EMAIL"))
	local compass_token = trim(os.getenv("COMPASS_API_TOKEN"))
	local jira_token = trim(os.getenv("JIRA_API_TOKEN"))

	local base_url = nil
	local base_url_env = nil
	if compass_base_url ~= nil and compass_base_url ~= "" then
		base_url = compass_base_url
		base_url_env = "COMPASS_BASE_URL"
	elseif jira_base_url ~= nil and jira_base_url ~= "" then
		base_url = jira_base_url
		base_url_env = "JIRA_BASE_URL"
	end

	local email_env = nil
	if has_value(compass_email) then
		email_env = "COMPASS_EMAIL"
	elseif has_value(jira_email) then
		email_env = "JIRA_EMAIL"
	end

	local token_env = nil
	if has_value(compass_token) then
		token_env = "COMPASS_API_TOKEN"
	elseif has_value(jira_token) then
		token_env = "JIRA_API_TOKEN"
	end

	compass._config = {
		base_url = base_url,
		base_url_env = base_url_env,
		email_env = email_env,
		token_env = token_env,
		graphql_path = graphql_path,
		var_statuses = {
			COMPASS_BASE_URL = { configured = has_value(compass_base_url), used = base_url_env == "COMPASS_BASE_URL", required = true, fallback = false },
			JIRA_BASE_URL = { configured = has_value(jira_base_url), used = base_url_env == "JIRA_BASE_URL", required = false, fallback = true },
			COMPASS_EMAIL = { configured = has_value(compass_email), used = email_env == "COMPASS_EMAIL", fallback = false },
			JIRA_EMAIL = { configured = has_value(jira_email), used = email_env == "JIRA_EMAIL", fallback = true },
			COMPASS_API_TOKEN = { configured = has_value(compass_token), used = token_env == "COMPASS_API_TOKEN", fallback = false, secret = true },
			JIRA_API_TOKEN = { configured = has_value(jira_token), used = token_env == "JIRA_API_TOKEN", fallback = true, secret = true },
		},
	}

	return compass._config
end

function client.validate_config()
	local cfg = client.get_config()
	local checks = clone_table(cfg.var_statuses)
	local issues = {}
	local compass_base = ensure_status(checks, "COMPASS_BASE_URL")
	local jira_base = ensure_status(checks, "JIRA_BASE_URL")
	local compass_email = ensure_status(checks, "COMPASS_EMAIL")
	local jira_email = ensure_status(checks, "JIRA_EMAIL")
	local compass_token = ensure_status(checks, "COMPASS_API_TOKEN")
	local jira_token = ensure_status(checks, "JIRA_API_TOKEN")

	local base_ok, base_err = client.validate_base_url(cfg.base_url)
	compass_base.valid = base_ok == true
	jira_base.valid = base_ok == true
	if not base_ok then
		local base_message = base_err and base_err.message or "Compass base URL is invalid"
		compass_base.error = base_message
		jira_base.error = base_message
		issues[#issues + 1] = base_message
	end

	if not (compass_email.configured or jira_email.configured) then
		local email_msg = "Either COMPASS_EMAIL or JIRA_EMAIL must be set"
		compass_email.error = email_msg
		jira_email.error = email_msg
		issues[#issues + 1] = email_msg
	end

	if not (compass_token.configured or jira_token.configured) then
		local token_msg = "Either COMPASS_API_TOKEN or JIRA_API_TOKEN must be set"
		compass_token.error = token_msg
		jira_token.error = token_msg
		issues[#issues + 1] = token_msg
	end

	if #issues > 0 then
		return false, validation_err(
			"Compass configuration is invalid: " .. table.concat(issues, "; "),
			{
				base_url = cfg.base_url,
				base_url_env = cfg.base_url_env,
				email_env = cfg.email_env,
				token_env = cfg.token_env,
				checks = checks,
			}
		)
	end

	return true, nil
end

function client.is_configured()
	local ok = client.validate_config()
	return ok == true
end

local function resolve_config()
	local cfg = client.get_config()
	local ok, err = client.validate_config()
	if not ok then
		return nil, err
	end
	return cfg, nil
end

function client.get_auth(cfg)
	if compass._auth then
		return compass._auth, nil
	end

	if cfg == nil then
		local resolved_cfg, err = resolve_config()
		if err then
			return nil, err
		end
		cfg = resolved_cfg
	end

	local email_ref = _raw.secrets.env(cfg.email_env)
	local token_ref = _raw.secrets.env(cfg.token_env)
	compass._auth = _raw.auth.basic(email_ref, token_ref)

	return compass._auth, nil
end

function client.get_cloud_id()
	if compass._cloud_id ~= nil then
		return compass._cloud_id, nil
	end

	local cfg, cfg_err = resolve_config()
	if cfg_err then
		return nil, cfg_err
	end

	local host_name = client.extract_host_name(cfg.base_url)
	if host_name == nil or host_name == "" then
		return nil, validation_err("Unable to extract host name from configured Compass base URL", { base_url = cfg.base_url, base_url_env = cfg.base_url_env })
	end

	local result, err = client.request(cloud_id_query, {
		hostName = host_name,
	}, {
		operation_name = "CompassCloudId",
	})
	if err then
		return nil, enrich_err(err, { base_url = cfg.base_url, path = cfg.graphql_path, operation_name = "CompassCloudId", host_name = host_name })
	end

	if type(result) ~= "table" or type(result.tenantContexts) ~= "table" or type(result.tenantContexts[1]) ~= "table" or result.tenantContexts[1].cloudId == nil then
		return nil, validation_err("Compass cloudId lookup returned an unexpected response shape", { host_name = host_name })
	end

	compass._cloud_id = result.tenantContexts[1].cloudId
	return compass._cloud_id, nil
end

function client.make_headers(opts)
	opts = opts or {}
	local headers = {
		{ name = "Accept", value = "application/json" },
		{ name = "Content-Type", value = "application/json" },
	}

	local experimental = opts.experimental_apis
	if experimental == nil then
		return headers, nil
	end

	if type(experimental) ~= "table" then
		return nil, validation_err("opts.experimental_apis must be an array of strings", { experimental_apis_type = type(experimental) })
	end

	for i, value in ipairs(experimental) do
		if type(value) ~= "string" or trim(value) == "" then
			return nil, validation_err("opts.experimental_apis entries must be non-empty strings", { index = i, value_type = type(value) })
		end
		table.insert(headers, { name = "X-ExperimentalApi", value = value })
	end

	return headers, nil
end

local function prepare_request(opts)
	opts = opts or {}

	local cfg, cfg_err = resolve_config()
	if cfg_err then
		return nil, nil, nil, cfg_err
	end

	local auth, auth_err = client.get_auth(cfg)
	if auth_err then
		return nil, nil, nil, auth_err
	end

	local headers, headers_err = client.make_headers(opts)
	if headers_err then
		return nil, nil, nil, headers_err
	end

	return cfg, auth, headers, nil
end

function client.request(document, variables, opts)
	opts = opts or {}

	local cfg, auth, headers, prep_err = prepare_request(opts)
	if prep_err then
		return nil, prep_err
	end

	local impl = client._request_impl or raw_graphql_request
	local result, err = impl(cfg.base_url, document, {
		path = cfg.graphql_path,
		variables = variables,
		operation_name = opts.operation_name,
		headers = headers,
		auth = auth,
		response_mode = opts.response_mode,
	})
	if err then
		return nil, enrich_err(err, {
			base_url = cfg.base_url,
			path = cfg.graphql_path,
			operation_name = opts.operation_name,
		})
	end

	return result, nil
end

function client.list(document, variables, pagination, opts)
	opts = opts or {}

	local cfg, auth, headers, prep_err = prepare_request(opts)
	if prep_err then
		return nil, prep_err
	end

	local impl = client._list_impl or raw_graphql_list
	local iter, err = impl(cfg.base_url, document, {
		path = cfg.graphql_path,
		variables = clone_table(variables),
		operation_name = opts.operation_name,
		headers = headers,
		auth = auth,
		pagination = pagination,
		limit = opts.limit,
		per_page = opts.per_page,
	})
	if err then
		return nil, enrich_err(err, {
			base_url = cfg.base_url,
			path = cfg.graphql_path,
			operation_name = opts.operation_name,
		})
	end

	return iter, nil
end
