-- preload/gitlab/branch.lua
-- Branch stateless API (no object wrapping)

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()
local raw_url_path_escape = sys.url.path_escape

gitlab.branch.__schema = {
	namespace = "gitlab.branch",
	service = "gitlab",
	functions = {
		{
			name = "create",
			path = "gitlab.branch.create",
			signature = "(repo, data)",
			returns_contract = "core.result",
			readonly = false,
			description = "Create a new branch from the specified ref (branch name or commit SHA)",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "data", type = "table", description = "Data: name (required), ref (required)" }
			},
			returns_typed = {
				{ name = "result", type = "Branch" },
				{ name = "err", type = "core.error|nil" }
			},
		},
		{
			name = "get",
			path = "gitlab.branch.get",
			signature = "(repo, branch_name)",
			returns_contract = "core.result",
			readonly = true,
			description = "Get details for a single branch",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "branch_name", type = "string" }
			},
			returns_typed = {
				{ name = "result", type = "Branch" },
				{ name = "err", type = "core.error|nil" }
			},
		},
		{
			name = "list",
			path = "gitlab.branch.list",
			signature = "(repo, opts)",
			returns_contract = "core.iter",
			yields = "Branch",
			readonly = true,
			description = "List branches for a repository (returns iterator; use helpers.collect() to materialize to array)",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "opts", type = "table", optional = true }
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" }
			},
		},
		{
			name = "delete",
			path = "gitlab.branch.delete",
			signature = "(repo, branch_name)",
			returns_contract = "core.result",
			readonly = false,
			description = "Delete a branch",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "branch_name", type = "string" }
			},
			returns_typed = {
				{ name = "result", type = "boolean" },
				{ name = "err", type = "core.error|nil" }
			},
		},
	},
	types = {
		Branch = {
			shape = "{name:string, protected?:boolean, merged?:boolean, default?:boolean, web_url?:string, commit?:table, ...}",
		}
	},
}

-- gitlab.branch.create(repo, data) -> (branch, err)
function gitlab.branch.create(repo, data)
	-- GitLab API: POST /projects/:id/repository/branches
	-- Query params: branch (name), ref (source)
	local body = {
		branch = data.name,
		ref = data.ref
	}

	return client.request_json("POST", repo, "repository/branches", nil, body)
end

-- gitlab.branch.get(repo, branch_name) -> (branch, err)
function gitlab.branch.get(repo, branch_name)
	-- GitLab API: GET /projects/:id/repository/branches/:branch
	-- URL encode the branch name
	local encoded_name = raw_url_path_escape(branch_name)
	return client.request_json("GET", repo, "repository/branches/" .. encoded_name, nil, nil)
end

-- gitlab.branch.list(repo, opts) -> iterator
-- Always returns iterator; use helpers.collect() to materialize to array
function gitlab.branch.list(repo, opts)
	opts = opts or {}

	local query = {}
	if opts.search ~= nil then
		query.search = opts.search
	end

	-- GitLab API: GET /projects/:id/repository/branches
	return client.list(repo, "repository/branches", query, opts)
end

-- gitlab.branch.delete(repo, branch_name) -> (success, err)
function gitlab.branch.delete(repo, branch_name)
	-- GitLab API: DELETE /projects/:id/repository/branches/:branch
	-- URL encode the branch name
	local encoded_name = raw_url_path_escape(branch_name)

	-- Use client.request_json for consistency
	local _result, err = client.request_json("DELETE", repo, "repository/branches/" .. encoded_name, nil, nil)

	if err then
		return nil, err
	end

	return true, nil
end
