-- Compass service pack
-- luacheck: globals compass _compass_client
-- Atlassian Compass GraphQL client

compass = {}

compass.__intro = [[
Use this service for Atlassian Compass components, component searches, and component activity.
Prefer targeted queries and materialize iterators only when needed.
]]

compass.__schema = {
	namespace = "compass",
	service = "compass",
	description = "Atlassian Compass GraphQL client. Requires COMPASS_BASE_URL or JIRA_BASE_URL plus COMPASS_EMAIL/COMPASS_API_TOKEN (or JIRA_EMAIL/JIRA_API_TOKEN fallbacks).",
	functions = {
		{
			name = "ready",
			path = "compass.ready",
			signature = "()",
			returns_contract = "core.result",
			description = "Check whether Compass is configured and reachable via the GraphQL gateway.",
			params = {},
			returns_typed = {
				{ name = "result", type = "boolean", description = "True when Compass configuration and auth are valid" },
				{ name = "err", type = "core.error|nil", description = "Error when Compass is not configured or the API request fails" },
			},
			readonly = true,
		},
		{
			name = "components",
			path = "compass.components",
			signature = "(ids, opts)",
			returns_contract = "core.result",
			description = "Fetch up to 30 Compass components by id.",
			params = {
				{ name = "ids", type = "string[]|number[]" },
				{ name = "opts", type = "table", optional = true, description = "Options: field_set, extra_selection, selection, experimental_apis, response_mode" },
			},
			returns_typed = {
				{ name = "result", type = "CompassComponent[]", description = "Matching Compass components" },
				{ name = "err", type = "core.error|nil", description = "Error when validation or GraphQL request fails" },
			},
			readonly = true,
		},
		{
			name = "component",
			path = "compass.component",
			signature = "(id, opts)",
			returns_contract = "core.result",
			description = "Fetch a single Compass component by id.",
			params = {
				{ name = "id", type = "string|number" },
				{ name = "opts", type = "table", optional = true, description = "Options: field_set, include_custom_fields, extra_selection, selection, experimental_apis, response_mode" },
			},
			returns_typed = {
				{ name = "result", type = "CompassComponent|nil", description = "Compass component when found" },
				{ name = "err", type = "core.error|nil", description = "Error when validation or GraphQL request fails" },
			},
			readonly = true,
		},
		{
			name = "searchComponents",
			path = "compass.searchComponents",
			signature = "(query, opts)",
			returns_contract = "core.iter",
			yields = "CompassComponent",
			description = "Search Compass components with cursor pagination (returns iterator; use helpers.collect(iterator, {limit=N}) to materialize).",
			params = {
				{ name = "query", type = "string|table" },
				{ name = "opts", type = "table", optional = true, description = "Options: field_set, extra_selection, selection, per_page, limit, sort, experimental_apis" },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			readonly = true,
		},
		{
			name = "componentLogs",
			path = "compass.componentLogs",
			signature = "(component_id, opts)",
			returns_contract = "core.iter",
			yields = "CompassComponentLog",
			description = "List Compass component logs with cursor pagination (returns iterator; use helpers.collect(iterator, {limit=N}) to materialize).",
			params = {
				{ name = "component_id", type = "string|number" },
				{ name = "opts", type = "table", optional = true },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			readonly = true,
		},
	},
	types = {
		CompassComponent = { shape = "{id?:string, typeId?:string, name?:string, slug?:string, url?:string, description?:string, state?:string, ownerId?:string, labels?:table, links?:table, customFields?:table, ...}" },
		CompassComponentLog = { shape = "{id?:string, action?:string, actor?:string, componentId?:string, discoveryStrategy?:string, fieldId?:string, source?:table, timestamp?:string, value?:string, ...}" },
	},
}

local client = nil

local function get_client()
	if client == nil then
		client = _compass_client
		_compass_client = nil
	end
	return client
end

compass._get_client = get_client
