-- preload/gitlab/commit.lua
-- Commit functions (stateless)

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()

gitlab.commit.__schema = {
	namespace = "gitlab.commit",
	service = "gitlab",
	functions = {
		{
			name = "get",
			signature = "(repo, sha)",
			returns_contract = "core.result",
			readonly = true,
			description = "Fetch a single commit by SHA",
			params = { { name = "repo", type = "string|number" }, { name = "sha", type = "string" } },
			returns_typed = { { name = "result", type = "Commit" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "list",
			signature = "(repo, opts)",
			returns_contract = "core.iter",
			yields = "Commit",
			readonly = true,
			description = "List commits for a repository (returns iterator; use helpers.collect() to materialize to array)",
			params = { { name = "repo", type = "string|number" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "diff",
			signature = "(repo, sha, opts)",
			returns_contract = "core.result",
			readonly = true,
			description = "Fetch a commit diff by SHA",
			params = { { name = "repo", type = "string|number" }, { name = "sha", type = "string" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "result", type = "table" }, { name = "err", type = "core.error|nil" } },
		},
	},
	types = {
		Commit = { shape = "{id?:string, short_id?:string, title?:string, message?:string, author_name?:string, authored_date?:string, committed_date?:string, web_url?:string, ...}" },
	},
}

function gitlab.commit.get(repo, sha)
	return client.request_json("GET", repo, "repository/commits/" .. sha, nil, nil)
end

function gitlab.commit.list(repo, opts)
	opts = opts or {}

	-- Build query parameters
	local query = {}
	if opts.ref_name ~= nil then
		query.ref_name = opts.ref_name
	end
	if opts.since ~= nil then
		query.since = opts.since
	end
	local until_val = opts["until"]
	if until_val ~= nil then
		query["until"] = until_val
	end
	if opts.path ~= nil then
		query.path = opts.path
	end
	if opts.with_stats ~= nil then
		query.with_stats = opts.with_stats
	end

	return client.list(repo, "repository/commits", query, opts)
end

function gitlab.commit.diff(repo, sha, opts)
	opts = opts or {}
	local query = {}
	if opts.page ~= nil then
		query.page = opts.page
	end
	if opts.per_page ~= nil then
		query.per_page = opts.per_page
	end
	return client.request_json("GET", repo, "repository/commits/" .. sha .. "/diff", query, nil)
end
