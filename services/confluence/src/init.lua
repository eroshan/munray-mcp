-- Confluence service pack
-- Confluence Cloud REST API v2

confluence = {
	page = {},
	search = {},
	_client = {},
}

confluence.__intro = [[
Use this service for Confluence pages and page content.
Prefer precise page identifiers, titles, or space-scoped queries.
]]

-- Schema metadata for capabilities discovery
confluence.__schema = {
	namespace = "confluence",
	service = "confluence",
	description = "Confluence REST API client. Page operations use REST API v2; search uses the REST search endpoint. Requires JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN environment variables.",
	functions = {
		{
			name = "ready",
			signature = "()",
			returns_contract = "core.result",
			description = "Check if the Confluence host is reachable by probing the /wiki/home page",
			params = {},
			returns_typed = {
				{ name = "result", type = "boolean", description = "True if Confluence is ready" },
				{ name = "err", type = "core.error|nil", description = "Error if not ready or host probe failed" },
			},
			guarded = false,
		},
	},
	resources = { "confluence.page", "confluence.search" },
}

-- Capture raw primitives at load time to prevent runtime tampering
local raw_http_request = sys.http.request
local raw_http_list = sys.http.list
local raw_url_query_escape = sys.url.query_escape

-- Internal: allow tests to stub transport without changing production call sites.
-- Not part of the public service API.
confluence._client._request_impl = raw_http_request
confluence._client._list_impl = raw_http_list

local function normalize_base_url(base_url)
	if type(base_url) ~= "string" then
		return base_url
	end

	local trimmed = base_url:gsub("%s+$", ""):gsub("^%s+", "")
	trimmed = trimmed:gsub("/$", "")
	if trimmed == "" then
		return trimmed
	end

	-- Confluence Cloud uses the /wiki context path. Accept only the tenant root
	-- or the explicit /wiki URL; anything else is an invalid base URL.
	if trimmed:match("^https://[^/]+$") then
		return trimmed .. "/wiki"
	end
	if trimmed:match("^https://[^/]+/wiki$") then
		return trimmed
	end

	return trimmed
end

local function missing_base_url_err(cfg)
	return {
		code = "VALIDATION_FAILED",
		message = "JIRA_BASE_URL is required (e.g. https://<domain>/ or https://<domain>/wiki)",
		context = {
			base_url = cfg and cfg.base_url or nil,
			base_url_env = cfg and cfg.base_url_env or "JIRA_BASE_URL",
		},
		recoverable = false,
		suggestion = "Set JIRA_BASE_URL to a value like https://example.atlassian.net/wiki",
	}
end

local function invalid_base_url_err(base_url)
	return {
		code = "VALIDATION_FAILED",
		message = "Invalid JIRA_BASE_URL. Use either https://<domain>/ or https://<domain>/wiki (no additional path segments).",
		context = { base_url = base_url },
		recoverable = false,
		suggestion = "Set JIRA_BASE_URL to a valid URL (e.g., https://example.atlassian.net/wiki)",
	}
end

function confluence._client.missing_required_field_err(field_name, resource_type)
	return {
		code = "MISSING_REQUIRED_FIELD",
		message = string.format("Required field '%s' is missing", field_name),
		context = { field = field_name, resource_type = resource_type },
		recoverable = true,
		suggestion = string.format("Provide the required '%s' field and retry", field_name),
	}
end

local function validate_base_url(base_url)
	return type(base_url) == "string" and base_url:match("^https://[^/]+/wiki$") ~= nil
end

local function build_query_string(query)
	if type(query) ~= "table" then
		return ""
	end

	local keys = {}
	for k, _ in pairs(query) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local parts = {}
	for _, k in ipairs(keys) do
		local v = query[k]
		if v ~= nil and type(v) ~= "table" then
			parts[#parts + 1] = raw_url_query_escape(tostring(k)) .. "=" .. raw_url_query_escape(tostring(v))
		end
	end

	if #parts == 0 then
		return ""
	end
	return "?" .. table.concat(parts, "&")
end

local function build_full_url(base_url, path, query)
	local qs = build_query_string(query)
	return tostring(base_url or "") .. tostring(path or "") .. qs
end

-- Expose for tests/debug (not part of public service API)
confluence._client._normalize_base_url = normalize_base_url

-- Configuration from environment (lazy-loaded)
function confluence._client.get_config()
	if confluence._config then
		return confluence._config
	end

	local jira_base_url = normalize_base_url(os.getenv("JIRA_BASE_URL"))

	confluence._config = {
		base_url = jira_base_url,
		base_url_env = "JIRA_BASE_URL",
		auth_email_env = "JIRA_EMAIL",
		auth_token_env = "JIRA_API_TOKEN",
	}

	return confluence._config
end

function confluence._client.get_base_url()
	local cfg = confluence._client.get_config()
	if not cfg.base_url or cfg.base_url == "" then
		return nil, missing_base_url_err(cfg), cfg
	end
	if not validate_base_url(cfg.base_url) then
		return nil, invalid_base_url_err(cfg.base_url), cfg
	end
	return cfg.base_url, nil, cfg
end

function confluence._client.get_auth()
	if confluence._auth then
		return confluence._auth, nil
	end

	local cfg = confluence._client.get_config()
	local email_ref = sys.secrets.env(cfg.auth_email_env)
	local token_ref = sys.secrets.env(cfg.auth_token_env)
	confluence._auth = sys.auth.basic(email_ref, token_ref)
	return confluence._auth, nil
end

-- Internal: Make authenticated request to Confluence REST API v2.
-- path: API path (e.g., "/api/v2/pages/123")
-- opts: { query = {}, body = {} }
function confluence._client.request(method, path, opts)
	opts = opts or {}

	local base_url, base_url_err, cfg = confluence._client.get_base_url()
	if base_url_err then
		return nil, base_url_err
	end

	local auth, err = confluence._client.get_auth()
	if err then
		return nil, err
	end

	local impl = confluence._client._request_impl or raw_http_request
	local result, req_err = impl(method, base_url, path, {
		auth = auth,
		query = opts.query,
		body = opts.body,
		headers = {
			["Accept"] = "application/json",
			["Content-Type"] = "application/json",
		},
	})

	if req_err then
		local full_url = build_full_url(base_url, path, opts.query)
		if type(req_err) == "table" then
			req_err.context = req_err.context or {}
			req_err.context.full_url = req_err.context.full_url or full_url
			req_err.context.base_url = req_err.context.base_url or cfg.base_url
			req_err.context.path = req_err.context.path or path
			req_err.context.query = req_err.context.query or opts.query
		else
			req_err = {
				code = "API_ERROR",
				message = tostring(req_err),
				context = { full_url = full_url, base_url = base_url, path = path, query = opts.query },
				recoverable = true,
				suggestion = "Check the API endpoint and retry",
			}
		end
		return nil, req_err
	end

	return result, nil
end

function confluence._client.list(path, opts)
	opts = opts or {}

	local base_url, base_url_err = confluence._client.get_base_url()
	if base_url_err then
		return nil, base_url_err
	end

	local auth, err = confluence._client.get_auth()
	if err then
		return nil, err
	end

	local impl = confluence._client._list_impl or raw_http_list
	return impl("GET", base_url, path, {
		auth = auth,
		query = opts.query,
		headers = {
			["Accept"] = "application/json",
		},
		pagination = opts.pagination,
		limit = opts.limit,
		per_page = opts.per_page,
	})
end

-- Check if Confluence is ready to handle requests.
-- Verifies the configured Confluence base URL by probing a lightweight page.
-- Returns: (true, nil) if ready, (false, err) if not ready
function confluence.ready()
	local base_url, base_url_err, cfg = confluence._client.get_base_url()
	if base_url_err then
		return false, base_url_err
	end

	local impl = confluence._client._request_impl or raw_http_request
	local _res, err = impl("HEAD", base_url, "/home", {
		headers = {
			["Accept"] = "text/html",
		},
	})
	if err then
		return false, {
			code = "API_ERROR",
			message = "Confluence home page check failed: " .. (err.message or tostring(err)),
			context = {
				base_url = base_url,
				base_url_env = cfg.base_url_env,
				full_url = err.context and err.context.full_url or nil,
				path = err.context and err.context.path or nil,
				query = err.context and err.context.query or nil,
				http_code = err.context and err.context.status or err.code,
			},
			recoverable = true,
			suggestion = "Verify the Confluence host is reachable and the base URL points at the Atlassian tenant",
		}
	end

	return true, nil
end
