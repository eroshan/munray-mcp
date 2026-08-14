-- Confluence search operations

local list_request = confluence._client.list
local missing_required_field_err = confluence._client.missing_required_field_err

local function validation_err(message, context)
	return {
		code = "VALIDATION_FAILED",
		message = message,
		context = context or {},
		recoverable = false,
		suggestion = "Check the parameter values and retry",
	}
end

local function normalize_expand(expand)
	if expand == nil then
		return nil
	end
	if type(expand) == "table" then
		return table.concat(expand, ",")
	end
	return tostring(expand)
end

local function normalize_cql_context(cql_context)
	if cql_context == nil then
		return nil
	end
	if type(cql_context) == "table" then
		return json.encode(cql_context, false)
	end
	return tostring(cql_context)
end

local function quote_cql_string(value)
	local text = tostring(value)
	for i = 1, #text do
		local b = string.byte(text, i)
		if b == 0 or (b < 32 and b ~= 9 and b ~= 10 and b ~= 13) then
			return nil, validation_err("Query contains unsupported control characters", {
				field = "query",
				resource_type = "search",
			})
		end
	end

	text = text:gsub("\\", "\\\\")
	text = text:gsub('"', '\\"')
	text = text:gsub("\n", "\\n")
	text = text:gsub("\r", "\\r")
	text = text:gsub("\t", "\\t")
	return '"' .. text .. '"', nil
end

local function build_page_search_cql(query)
	local quoted_query, err = quote_cql_string(query)
	if err then
		return nil, err
	end

	return "siteSearch ~ " .. quoted_query .. " AND type = page", nil
end

function confluence.search.find(cql, opts)
	if cql == nil or tostring(cql) == "" then
		return nil, missing_required_field_err("cql", "search")
	end

	opts = opts or {}

	local query = {
		cql = tostring(cql),
		cqlcontext = normalize_cql_context(opts.cqlcontext),
		expand = normalize_expand(opts.expand),
		excerpt = opts.excerpt,
		includeArchivedSpaces = opts.include_archived_spaces,
	}

	local iterator, err = list_request("/rest/api/search", {
		query = query,
		pagination = {
			kind = "offset",
			items_path = "results",
			offset_param = "start",
			limit_param = "limit",
			start_offset = opts.start or 0,
			total_path = "totalSize",
		},
		limit = opts.limit,
		per_page = opts.per_page or 25,
	})
	if err then
		return nil, err
	end

	return iterator, nil
end

function confluence.search.pages(query, opts)
	if query == nil or tostring(query) == "" then
		return nil, missing_required_field_err("query", "search")
	end

	local cql, err = build_page_search_cql(query)
	if err then
		return nil, err
	end

	return confluence.search.find(cql, opts)
end

confluence.search.__schema = {
	namespace = "confluence.search",
	service = "confluence",
	description = "Confluence search operations using CQL over the REST search API.",
	functions = {
		{
			name = "find",
			signature = "(cql, opts?)",
			description = "Search Confluence with CQL. Returns a lazy iterator of search results.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "SearchResult",
			params = {
				{ name = "cql", type = "string", optional = false, description = "Confluence Query Language expression" },
				{ name = "opts", type = "table", optional = true, description = "Options: cqlcontext, expand, excerpt, include_archived_spaces, start, per_page, limit" },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
-- Search for documentation pages
local results = helpers.collect(
  confluence.search.find("siteSearch ~ 'runbook' AND type = page", {
    limit = 5,
    excerpt = "highlight",
  })
)
return results
			]],
		},
		{
			name = "pages",
			signature = "(query, opts?)",
			description = "Search Confluence pages by plain-text query. Builds page-scoped CQL and returns a lazy iterator of search results.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "SearchResult",
			params = {
				{ name = "query", type = "string", optional = false, description = "Plain-text query to match against indexed page content" },
				{ name = "opts", type = "table", optional = true, description = "Options: cqlcontext, expand, excerpt, include_archived_spaces, start, per_page, limit" },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
-- Search pages with a plain-text query
local results = helpers.collect(
  confluence.search.pages("runbook", {
    limit = 5,
    excerpt = "highlight",
  })
)
return results
			]],
		},
	},
	types = {
		SearchResult = { shape = "{title?:string, excerpt?:string, url?:string, entityType?:string, entity?:table, resultGlobalContainer?:table, _links?:table}" },
	},
}
