-- preload/gitlab/search.lua
-- GitLab Search API (group-scoped)

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()

-- Default group path for examples; callers may override it with opts.group_id.
local DEFAULT_GROUP_ID = "example-group"

gitlab.search.__schema = {
	namespace = "gitlab.search",
	service = "gitlab",
	functions = {
		{
			name = "find",
			signature = "(scope, query, opts)",
			returns_contract = "core.iter",
			yields = "SearchItem",
			guarded = false,
			description = "Search within a GitLab group. Set opts.group_id to the target group path. Returns an iterator; use helpers.collect() to materialize it to an array. Supported scopes: 'projects', 'blobs', 'merge_requests', 'commits', 'issues', 'milestones', 'users', 'wiki_blobs', 'notes'.",
			params = {
				{ name = "scope", type = "string", description = "Search scope: 'projects', 'blobs', 'merge_requests', 'commits', 'issues', 'milestones', 'users', 'wiki_blobs', 'notes'" },
				{ name = "query", type = "string", description = "Search term (supports filters like 'filename:*.lua' for blobs)" },
				{ name = "opts", type = "table", optional = true, description = "Options: group_id, state, ref, order_by, sort, per_page, limit, confidential, search_type, fields, include_archived, exclude_forks" }
			},
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
	},
	types = {
		SearchItem = { shape = "{id?:number|string, iid?:number, title?:string, name?:string, path_with_namespace?:string, web_url?:string, ...}" },
	},
}

-- gitlab.search.find(scope, query, opts) -> iterator
-- Always returns iterator; use helpers.collect() to materialize to array
-- Searches within the requested group, or the neutral example group by default.
function gitlab.search.find(scope, query, opts)
	opts = opts or {}
	local group_id = opts.group_id or DEFAULT_GROUP_ID

	-- Build query parameters
	local query_params = {
		scope = scope,
		search = query,
	}

	-- Optional filters
	if opts.state ~= nil then
		query_params.state = opts.state
	end
	if opts.ref ~= nil then
		query_params.ref = opts.ref
	end
	if opts.order_by ~= nil then
		query_params.order_by = opts.order_by
	end
	if opts.sort ~= nil then
		query_params.sort = opts.sort
	end
	if opts.confidential ~= nil then
		query_params.confidential = opts.confidential
	end
	if opts.search_type ~= nil then
		query_params.search_type = opts.search_type
	end
	if opts.include_archived ~= nil then
		query_params.include_archived = opts.include_archived
	end
	if opts.exclude_forks ~= nil then
		query_params.exclude_forks = opts.exclude_forks
	end
	if opts.fields ~= nil then
		if type(opts.fields) == "table" then
			-- GitLab API expects comma-separated values for array parameters
			query_params.fields = table.concat(opts.fields, ",")
		else
			query_params.fields = opts.fields
		end
	end

	return client.group_list(group_id, "search", query_params, opts)
end
