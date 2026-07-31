-- preload/gitlab/repo.lua
-- Repository functions (no object wrapping needed - stateless)

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()

gitlab.repo.__schema = {
	namespace = "gitlab.repo",
	service = "gitlab",
	functions = {
		{
			name = "get",
			path = "gitlab.repo.get",
			signature = "(repo)",
			returns_contract = "core.result",
			mutating = false,
			description = "Fetch repository info",
			params = { { name = "repo", type = "string|number" } },
			returns_typed = { { name = "result", type = "Repo" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "branches",
			path = "gitlab.repo.branches",
			signature = "(repo, opts)",
			returns_contract = "core.iter",
			yields = "Branch",
			mutating = false,
			description = "List branches for a repository",
			params = { { name = "repo", type = "string|number" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "tree",
			path = "gitlab.repo.tree",
			signature = "(repo, opts)",
			returns_contract = "core.iter",
			yields = "TreeEntry",
			mutating = false,
			description = "List repository files and directories (returns iterator; use helpers.collect() to materialize to array)",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "opts", type = "table", optional = true, description = "Options: path, ref, recursive, per_page, limit" },
			},
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "compare",
			path = "gitlab.repo.compare",
			signature = "(repo, from, to)",
			returns_contract = "core.result",
			mutating = false,
			description = "Compare two branches",
			params = { { name = "repo", type = "string|number" }, { name = "from", type = "string" }, { name = "to", type = "string" } },
			returns_typed = { { name = "result", type = "CompareResult" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "file",
			path = "gitlab.repo.file",
			signature = "(repo, path, ref)",
			returns_contract = "core.result",
			mutating = false,
			description = "Fetch file contents",
			params = { { name = "repo", type = "string|number" }, { name = "path", type = "string" }, { name = "ref", type = "string" } },
			returns_typed = { { name = "result", type = "string" }, { name = "err", type = "core.error|nil" } },
		},
	},
	types = {
		Repo = { shape = "{id?:number, name?:string, path_with_namespace?:string, web_url?:string, default_branch?:string, ...}" },
		Branch = { shape = "{name:string, merged?:boolean, protected?:boolean, default?:boolean, commit?:table, web_url?:string, ...}" },
		TreeEntry = { shape = "{id:string, name:string, type:string, path:string, mode?:string, ...}" },
		CompareResult = { shape = "{commit?:table, commits?:table, diffs?:table, compare_timeout?:boolean, compare_timeout_message?:string, ...}" },
	},
}

function gitlab.repo.get(repo)
	-- Empty path = project info endpoint
	return client.request_json("GET", repo, "", nil, nil)
end

function gitlab.repo.branches(repo, opts)
	-- Delegate to canonical gitlab.branch.list implementation
	return gitlab.branch.list(repo, opts)
end

function gitlab.repo.tree(repo, opts)
	opts = opts or {}

	local query = {}
	if opts.path ~= nil then
		query.path = opts.path
	end
	if opts.ref ~= nil then
		query.ref = opts.ref
	end
	if opts.recursive ~= nil then
		query.recursive = opts.recursive
	end

	return client.list(repo, "repository/tree", query, opts)
end

function gitlab.repo.compare(repo, from, to)
	local query = { from = from, to = to }
	return client.request_json("GET", repo, "repository/compare", query, nil)
end

local raw_url_path_escape = _raw.url.path_escape

function gitlab.repo.file(repo, path, ref)
	local query = { ref = ref or "" }
	local encoded_path = raw_url_path_escape(path)
	-- GitLab returns raw file bytes here, so use the text variant to avoid JSON parsing errors
	return client.request_text("GET", repo, "repository/files/" .. encoded_path .. "/raw", query)
end
