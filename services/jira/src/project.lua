-- Jira project operations

jira.project.__schema = {
    namespace = "jira.project",
    service = "jira",
    description = "Jira project operations",
    functions = {
        {
            name = "get",
            path = "jira.project.get",
            signature = "(project_key, opts)",
            returns_contract = "core.result",
            description = "Get a project by key",
            params = {
                { name = "project_key", type = "string", description = "Project key (e.g., 'PROJ')" },
                { name = "opts", type = "table", optional = true, description = "Options: expand" }
            },
            returns_typed = {
                { name = "result", type = "Project", description = "Project object" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            readonly = true
        },
        {
            name = "list",
            path = "jira.project.list",
            signature = "(opts)",
            returns_contract = "core.iter",
            yields = "Project",
            description = "List all projects",
            params = {
                { name = "opts", type = "table", optional = true, description = "Options: limit, per_page, expand" }
            },
            returns_typed = {
                { name = "iterator", type = "Iterator", description = "Iterator yielding Project objects" }
            },
            readonly = true
        }
    },
	types = {
		Project = { shape = "{id?:string, key?:string, name?:string, self?:string, projectTypeKey?:string, simplified?:boolean, ...}" },
	}
}

-- Get project by key
-- opts: { expand = "description,lead" }
function jira.project.get(project_key, opts)
    if not project_key or project_key == "" then
        return nil, {
            code = "VALIDATION",
            message = "project_key is required",
            recoverable = false
        }
    end

    opts = opts or {}
    local query = {}

    if opts.expand then
        query.expand = opts.expand
    end

    local path = "/rest/api/3/project/" .. project_key
    return jira._client.request("GET", path, { query = query })
end

-- List all projects
-- opts: { limit, per_page, expand }
function jira.project.list(opts)
    opts = opts or {}

    local query = {}
    if opts.expand then
        query.expand = opts.expand
    end

    return jira._client.list("/rest/api/3/project/search", {
        query = query,
        items_path = "values",
        limit = opts.limit,
        per_page = opts.per_page or 50
    })
end
