-- Jira field operations

jira.field.__schema = {
    namespace = "jira.field",
    service = "jira",
    description = "Jira field metadata discovery",
    functions = {
        {
            name = "list",
            path = "jira.field.list",
            signature = "(opts)",
            returns_contract = "core.iter",
            yields = "Field",
            description = "List Jira fields with optional case-insensitive substring filtering by name",
            params = {
                { name = "opts", type = "table", optional = true, description = "Options: query, limit" }
            },
            returns_typed = {
                { name = "iterator", type = "Iterator", description = "Iterator yielding compact Field objects" }
            },
            readonly = true,
            examples = [[
local iter, err = jira.field.list({ query = "target", limit = 10 })
if err then error(err.message or tostring(err)) end

for field in iter do
    print(field.id, field.name, field.type, field.custom)
end
]],
        }
    },
    types = {
        Field = { shape = "{id?:string, name?:string, type?:string, custom:boolean}" },
    },
}

local function normalize_query(query)
    if query == nil then
        return nil
    end

    if type(query) ~= "string" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "opts.query must be a string when provided",
            recoverable = true,
            suggestion = "Provide a string query, e.g., { query = 'target' }"
        }
    end

    local trimmed = query:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return nil
    end

    return string.lower(trimmed), nil
end

local function normalize_field(field)
    local field_id = field.id or field.key
    local field_type = nil
    if type(field.schema) == "table" then
        field_type = field.schema.type
    end

    return {
        id = field_id,
        name = field.name,
        type = field_type,
        custom = field.custom == true or (type(field_id) == "string" and string.match(field_id, "^customfield_") ~= nil) or false,
    }
end

function jira.field.list(opts)
    if opts ~= nil and type(opts) ~= "table" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "opts must be a table when provided",
            recoverable = true,
            suggestion = "Provide options as a table, e.g., { query = 'target', limit = 10 }"
        }
    end

    opts = opts or {}

    if opts.limit ~= nil and (type(opts.limit) ~= "number" or opts.limit < 1) then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "opts.limit must be a positive number when provided",
            recoverable = true,
            suggestion = "Provide a positive limit, e.g., { limit = 10 }"
        }
    end

    local query, query_err = normalize_query(opts.query)
    if query_err then
        return nil, query_err
    end

    local fields, err = jira._client.request("GET", "/rest/api/3/field", {})
    if err then
        return nil, err
    end

    if type(fields) ~= "table" then
        return nil, {
            code = "UNEXPECTED_RESPONSE",
            message = "Jira field list response was not an array",
            recoverable = false,
            context = {
                endpoint = "/rest/api/3/field",
                response_type = type(fields),
            }
        }
    end

    local index = 0
    local yielded = 0
    local limit = opts.limit

    return function()
        while true do
            index = index + 1
            local field = fields[index]
            if field == nil then
                return nil
            end

            local normalized = normalize_field(field)
            local field_name = normalized.name
            local matches = true
            if query ~= nil then
                if type(field_name) ~= "string" then
                    matches = false
                else
                    matches = string.find(string.lower(field_name), query, 1, true) ~= nil
                end
            end

            if matches then
                yielded = yielded + 1
                if limit ~= nil and yielded > limit then
                    return nil
                end
                return normalized, nil
            end
        end
    end, nil
end
