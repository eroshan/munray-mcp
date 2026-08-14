-- Jira client initialization (Lua-first implementation)
-- All API logic lives in Lua, using sys.http.request for transport

jira = {
    issue = {},
    project = {},
    field = {},
    _client = {},
    _configured = false
}

jira.__intro = [[
Use this service for Jira issues, projects, and fields.
Prefer explicit project keys, issue keys, and narrow search criteria.
]]

-- Schema metadata for capabilities discovery
jira.__schema = {
    namespace = "jira",
    service = "jira",
    description = "Jira Cloud REST API client. Requires JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN environment variables.",
    functions = {
        {
            name = "ready",
            path = "jira.ready",
            signature = "()",
            returns_contract = "core.result",
            description = "Check if Jira is configured and ready to handle requests by verifying authentication",
            params = {},
            returns_typed = {
                { name = "result", type = "boolean", description = "True if Jira is ready" },
                { name = "err", type = "core.error|nil", description = "Error if not ready or auth failed" }
            },
            readonly = true
        }
    },
    resources = { "jira.issue", "jira.project", "jira.field" }
}

-- Configuration from environment (lazy-loaded)
function jira._client.get_config()
    if jira._config then
        return jira._config
    end

    jira._config = {
        base_url = os.getenv("JIRA_BASE_URL"),
        email = os.getenv("JIRA_EMAIL"),
        token = os.getenv("JIRA_API_TOKEN")
    }

    return jira._config
end

-- Check if Jira is configured
function jira._client.is_configured()
    local cfg = jira._client.get_config()
    return cfg.base_url and cfg.base_url ~= "" and
           cfg.email and cfg.email ~= "" and
           cfg.token and cfg.token ~= ""
end

-- Get authentication reference (cached)
function jira._client.get_auth()
    if jira._auth then
        return jira._auth
    end

    local _cfg = jira._client.get_config()
    if not jira._client.is_configured() then
        return nil, {
            code = "VALIDATION",
            message = "Jira not configured. Set JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN environment variables.",
            recoverable = false
        }
    end

    local email_ref = sys.secrets.env("JIRA_EMAIL")
    local token_ref = sys.secrets.env("JIRA_API_TOKEN")
    jira._auth = sys.auth.basic(email_ref, token_ref)

    return jira._auth
end

-- Check if Jira is ready to handle requests
-- Verifies configuration and tests authentication by calling the API
-- Returns: (true, nil) if ready, (false, err) if not ready
function jira.ready()
    -- First check configuration
    if not jira._client.is_configured() then
        return false, {
            code = "VALIDATION",
            message = "Jira not configured. Set JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN environment variables.",
            recoverable = false
        }
    end

    -- Verify authentication by making a test API call to /rest/api/3/myself
    -- This endpoint returns the current user info and is a lightweight way to test auth
    local user, err = jira._client.request("GET", "/rest/api/3/myself", {})
    if err then
        return false, {
            code = "AUTH_FAILED",
            message = "Jira authentication failed: " .. (err.message or tostring(err)),
            context = { base_url = jira._client.get_config().base_url },
            recoverable = false
        }
    end

    -- Verify we got a valid response with user info
    if not user or not user.accountId then
        return false, {
            code = "AUTH_FAILED",
            message = "Jira authentication succeeded but response is invalid",
            recoverable = false
        }
    end

    return true, nil
end

-- Internal: Make authenticated request to Jira API
-- path: API path (e.g., "/rest/api/3/issue/PROJ-123")
-- opts: { method = "GET", query = {}, body = {} }
function jira._client.request(method, path, opts)
    opts = opts or {}

    local auth, err = jira._client.get_auth()
    if err then
        return nil, err
    end

    local cfg = jira._client.get_config()
    local full_opts = {
        auth = auth,
        query = opts.query,
        body = opts.body,
        headers = {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json"
        }
    }

    return sys.http.request(method, cfg.base_url, path, full_opts)
end

-- Internal: Make paginated list request using offset-based pagination
-- NOTE: This is for legacy/non-search endpoints. New code should use token-based pagination.
-- path: API path
-- opts: { query = {}, limit = 100, per_page = 50 }
function jira._client.list(path, opts)
    opts = opts or {}

    local auth, err = jira._client.get_auth()
    if err then
        return nil, err
    end

    local cfg = jira._client.get_config()

    return sys.http.list("GET", cfg.base_url, path, {
        auth = auth,
        query = opts.query,
        headers = {
            ["Accept"] = "application/json"
        },
        pagination = {
            kind = "offset",
            items_path = opts.items_path or "values",
            offset_param = "startAt",
            limit_param = "maxResults",
            start_offset = 0,
            total_path = "total"
        },
        limit = opts.limit,
        per_page = opts.per_page or 50
    })
end
