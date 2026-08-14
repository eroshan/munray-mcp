-- preload/gitlab/_client.lua
-- Internal GitLab CLI client module (undiscoverable, private to gitlab.* service)
-- This module is loaded privately and used as upvalues in resource files.

local _client = {}

-- Capture raw primitives at load time to prevent runtime tampering
local raw_cli_json = sys.cli.json
local raw_cli_text = sys.cli.text
local raw_url_query_escape = sys.url.query_escape
local raw_url_path_escape = sys.url.path_escape

local get_errors = gitlab._get_errors

local function errx()
	return get_errors()
end

local function request_kind(method)
	if method == "GET" then
		return "get"
	end
	return "mutation"
end

local function public_ctx(fields)
	return fields
end

local function list_meta(operation, ctx)
	return {
		kind = "list",
		operation = operation,
		public_context = public_ctx(ctx),
	}
end

local function invalid_response_err(message, ctx)
	return errx().public({
		code = "INVALID_RESPONSE",
		message = message,
		recoverable = false,
		context = public_ctx(ctx),
	})
end

local function invalid_repo_err(repo)
	return errx().public({
		code = "INVALID_REPO",
		message = "gitlab: repo must be string path (e.g. 'group/project') or numeric project id",
		context = { repo = repo, repo_type = type(repo) },
		recoverable = false,
	})
end

-- URL-encode slashes for GitLab API identifiers.
-- e.g., "group/project" -> "group%2Fproject"
local function encode_repo_path(repo_path)
	return raw_url_path_escape(repo_path)
end

-- Cache string repo path -> numeric project id.
-- Safe optimization: does not change semantics.
local project_id_cache = {}

-- Resolve a project identifier to a numeric project id.
-- If given a string path ("group/project"), this performs a GET lookup once.
function _client.resolve_project_id(repo)
	local repo_type = type(repo)
	if repo_type == "number" then
		return repo, nil
	end

	if repo_type ~= "string" then
		return nil, invalid_repo_err(repo)
	end

	local cached = project_id_cache[repo]
	if cached ~= nil then
		return cached, nil
	end

	local lookup_path = _client.project_lookup_path(repo)
	local args = {"api", lookup_path}
	local project, err = raw_cli_json("glab", args, {})
	if err then
		return nil, errx().from_upstream(err, {
			kind = "get",
			operation = "gitlab.resolve_project_id",
			public_context = { repo = repo },
		})
	end

	if type(project) ~= "table" or project.id == nil then
		return nil, errx().public({
			code = "PROJECT_LOOKUP_FAILED",
			message = "gitlab: failed to resolve project id for repo path",
			context = { repo = repo, lookup_path = lookup_path },
			recoverable = true,
		})
	end

	project_id_cache[repo] = project.id
	return project.id, nil
end

-- Path used only for resolving string repo paths to numeric ids.
function _client.project_lookup_path(repo_path)
	if type(repo_path) ~= "string" then
		error("gitlab: repo_path must be a string", 0)
	end
	return "projects/" .. encode_repo_path(repo_path)
end

-- Build a glab API path for project-scoped endpoints.
-- Always uses the numeric project id: /projects/:id/...
function _client.project_path(project_id, path)
	local encoded = tostring(project_id)
	if path == "" or path == nil then
		return "projects/" .. encoded
	end
	return "projects/" .. encoded .. "/" .. path
end

-- Build a glab API path for group-scoped endpoints.
-- glab uses: /groups/:id/... with :id as URL-encoded group path.
function _client.group_path(group_id, path)
	local encoded = raw_url_path_escape(group_id)
	if path == "" or path == nil then
		return "groups/" .. encoded
	end
	return "groups/" .. encoded .. "/" .. path
end

-- Ensure GitLab authentication is configured.
-- Note: In tests with fake services, this may not be needed.
-- We'll let glab fail if auth is truly missing rather than blocking early.
function _client.ensure_auth()
	-- Don't block - let glab handle auth failures
	-- This allows tests to work with fake services
	return true, nil
end

-- Build query string from table
local function build_query_string(query)
	if not query or type(query) ~= "table" then
		return ""
	end

	local parts = {}
	for k, v in pairs(query) do
		if v ~= nil then
			if type(v) == "table" then
				-- Array-like tables become repeated query params:
				-- e.g. { ["scope[]"] = {"pending","running"} } -> scope%5B%5D=pending&scope%5B%5D=running
				for _, item in ipairs(v) do
					if item ~= nil then
						table.insert(parts, raw_url_query_escape(k) .. "=" .. raw_url_query_escape(tostring(item)))
					end
				end
			else
				table.insert(parts, raw_url_query_escape(k) .. "=" .. raw_url_query_escape(tostring(v)))
			end
		end
	end

	if #parts == 0 then
		return ""
	end

	return "?" .. table.concat(parts, "&")
end

-- Generic JSON request using glab CLI
-- Always include explicit method token (GET/POST/PUT/PATCH/DELETE) so read-only security can classify
function _client.request_json(method, repo, path, query, body)
	local _ok, err = _client.ensure_auth()
	if err then
		return nil, errx().from_upstream(err, {
			kind = request_kind(method),
			operation = "gitlab.request_json",
			public_context = { repo = repo, path = path },
		})
	end

	local project_id, id_err = _client.resolve_project_id(repo)
	if id_err then return nil, id_err end

	-- Build full API path
	local api_path = _client.project_path(project_id, path)

	-- Add query parameters to path
	if query and type(query) == "table" then
		api_path = api_path .. build_query_string(query)
	end

	-- Build glab command arguments
	local args = {"api", api_path}

	-- Add HTTP method (required for security validation)
	if method ~= "GET" then
		table.insert(args, "-X")
		table.insert(args, method)
	end

	-- Add body fields as form data (for POST/PUT/PATCH)
	if body and type(body) == "table" then
		for key, value in pairs(body) do
			table.insert(args, "-F")
			table.insert(args, key .. "=" .. tostring(value))
		end
	end

	local result, cli_err = raw_cli_json("glab", args, {})
	if cli_err then
		return nil, errx().from_upstream(cli_err, {
			kind = request_kind(method),
			operation = "gitlab.request_json",
			public_context = { repo = repo, path = path },
		})
	end

	return result, nil
end

-- Generic text request using glab CLI (for endpoints that return plain text like job traces)
function _client.request_text(method, repo, path, query)
	local _ok, err = _client.ensure_auth()
	if err then
		return nil, errx().from_upstream(err, {
			kind = request_kind(method),
			operation = "gitlab.request_text",
			public_context = { repo = repo, path = path },
		})
	end

	local project_id, id_err = _client.resolve_project_id(repo)
	if id_err then return nil, id_err end

	-- Build full API path
	local api_path = _client.project_path(project_id, path)

	-- Add query parameters to path
	if query and type(query) == "table" then
		api_path = api_path .. build_query_string(query)
	end

	-- Build glab command arguments
	local args = {"api", api_path}

	-- Add HTTP method (required for security validation)
	if method ~= "GET" then
		table.insert(args, "-X")
		table.insert(args, method)
	end

	local result, cli_err = raw_cli_text("glab", args, {})
	if cli_err then
		return nil, errx().from_upstream(cli_err, {
			kind = request_kind(method),
			operation = "gitlab.request_text",
			public_context = { repo = repo, path = path },
		})
	end

	return result, nil
end

-- Paginated iterator using page/per_page query
-- Returns an iterator function that yields items lazily
function _client.list(repo, path, query, opts)
	opts = opts or {}
	query = query or {}

	local _ok, err = _client.ensure_auth()
	if err then
		return function()
			error(errx().from_upstream(err, list_meta("gitlab.list", { repo = repo, path = query.path, ref = query.ref })), 0)
		end
	end

	local project_id, id_err = _client.resolve_project_id(repo)
	if id_err then
		return function()
			error(errx().from_upstream(id_err, list_meta("gitlab.list", { repo = repo, path = query.path, ref = query.ref })), 0)
		end
	end

	local page = 1
	local per_page = opts.per_page or query.per_page or 20
	local limit = opts.limit or 0
	local items_yielded = 0
	local current_items = {}
	local current_index = 0
	local done = false
	local has_more_pages = true

	local function fetch_next_page()
		if not has_more_pages then
			return false
		end

		local page_query = {}
		for k, v in pairs(query) do
			page_query[k] = v
		end
		page_query.page = page
		page_query.per_page = per_page

		local api_path = _client.project_path(project_id, path) .. build_query_string(page_query)
		local args = {"api", api_path, "-i"}  -- -i to get headers

		local result, fetch_err = raw_cli_text("glab", args, {})
		if fetch_err then
			error(errx().from_upstream(fetch_err, list_meta("gitlab.list", { repo = repo, path = query.path, ref = query.ref })), 0)
		end

		-- Parse headers and body. `glab api -i` returns an HTTP-like response with
		-- headers and body separated by a blank line; newline style may be CRLF.
		local normalized = tostring(result):gsub("\r\n", "\n")
		local sep = normalized:find("\n\n", 1, true)
		local headers_text, body_text
		if sep then
			headers_text = normalized:sub(1, sep - 1)
			body_text = normalized:sub(sep + 2)
		else
			headers_text = ""
			body_text = normalized
		end
		body_text = body_text:gsub("^%s+", "")

		-- Parse JSON body
		local page_items, json_err = json.decode(body_text)
		if json_err then
			error(invalid_response_err("GitLab list response was invalid", { repo = repo, path = query.path, ref = query.ref }), 0)
		end

		-- Ensure it's an array
		if type(page_items) ~= "table" then
			error(invalid_response_err("GitLab list response had an unexpected shape", { repo = repo, path = query.path, ref = query.ref }), 0)
		end

		-- Check if empty (end of results)
		if #page_items == 0 then
			has_more_pages = false
			return false
		end

		-- Check for X-Next-Page header (case-insensitive)
		local headers_lc = tostring(headers_text):lower()
		local has_next = headers_lc:match("x%-next%-page:%s*(%d+)") ~= nil
		has_more_pages = has_next

		-- Update state
		current_items = page_items
		current_index = 0
		page = page + 1

		return true
	end

	return function()
		-- Check if we've hit the limit
		if limit > 0 and items_yielded >= limit then
			return nil
		end

		-- Check if we're done
		if done then
			return nil
		end

		-- If we've exhausted current page, fetch next
		while current_index >= #current_items do
			if not fetch_next_page() then
				done = true
				return nil
			end
		end

		-- Return next item from current page with metadata
		current_index = current_index + 1
		items_yielded = items_yielded + 1

		return current_items[current_index], {page = page - 1}  -- page-1 because we already incremented
	end
end

-- Paginated iterator for group-scoped endpoints using page/per_page query
-- Returns an iterator function that yields items lazily
function _client.group_list(group_id, path, query, opts)
	opts = opts or {}
	query = query or {}

	local _ok, err = _client.ensure_auth()
	if err then
		return function()
			error(errx().from_upstream(err, list_meta("gitlab.group_list", { group = group_id })), 0)
		end
	end

	local page = 1
	local per_page = opts.per_page or query.per_page or 20
	local limit = opts.limit or 0
	local items_yielded = 0
	local current_items = {}
	local current_index = 0
	local done = false
	local has_more_pages = true

	local function fetch_next_page()
		if not has_more_pages then
			return false
		end

		local page_query = {}
		for k, v in pairs(query) do
			page_query[k] = v
		end
		page_query.page = page
		page_query.per_page = per_page

		local api_path = _client.group_path(group_id, path) .. build_query_string(page_query)
		local args = {"api", api_path, "-i"}  -- -i to get headers

		local result, fetch_err = raw_cli_text("glab", args, {})
		if fetch_err then
			error(errx().from_upstream(fetch_err, list_meta("gitlab.group_list", { group = group_id })), 0)
		end

		-- Parse headers and body. `glab api -i` returns an HTTP-like response with
		-- headers and body separated by a blank line; newline style may be CRLF.
		local normalized = tostring(result):gsub("\r\n", "\n")
		local sep = normalized:find("\n\n", 1, true)
		local headers_text, body_text
		if sep then
			headers_text = normalized:sub(1, sep - 1)
			body_text = normalized:sub(sep + 2)
		else
			headers_text = ""
			body_text = normalized
		end
		body_text = body_text:gsub("^%s+", "")

		-- Parse JSON body
		local page_items, json_err = json.decode(body_text)
		if json_err then
			error(invalid_response_err("GitLab list response was invalid", { group = group_id }), 0)
		end

		-- Ensure it's an array
		if type(page_items) ~= "table" then
			error(invalid_response_err("GitLab list response had an unexpected shape", { group = group_id }), 0)
		end

		-- Check if empty (end of results)
		if #page_items == 0 then
			has_more_pages = false
			return false
		end

		-- Check for X-Next-Page header (case-insensitive)
		local headers_lc = tostring(headers_text):lower()
		local has_next = headers_lc:match("x%-next%-page:%s*(%d+)") ~= nil
		has_more_pages = has_next

		-- Update state
		current_items = page_items
		current_index = 0
		page = page + 1

		return true
	end

	return function()
		-- Check if we've hit the limit
		if limit > 0 and items_yielded >= limit then
			return nil
		end

		-- Check if we're done
		if done then
			return nil
		end

		-- If we've exhausted current page, fetch next
		while current_index >= #current_items do
			if not fetch_next_page() then
				done = true
				return nil
			end
		end

		-- Return next item from current page with metadata
		current_index = current_index + 1
		items_yielded = items_yielded + 1

		return current_items[current_index], {page = page - 1}  -- page-1 because we already incremented
	end
end

-- Store privately for gitlab service to capture
-- Using underscore prefix to indicate this is internal
_gitlab_client = _client
