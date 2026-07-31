-- Jira issue operations

jira.issue.__schema = {
    namespace = "jira.issue",
    service = "jira",
    description = "Jira issue operations (get, list, search, create, update)",
    functions = {
        {
            name = "get",
            path = "jira.issue.get",
            signature = "(issue_key, opts)",
            returns_contract = "core.result",
            description = "Get a single issue by key",
            params = {
                { name = "issue_key", type = "string", description = "Issue key (e.g., 'PROJ-123')" },
                { name = "opts", type = "table", optional = true, description = "Options: fields, expand" }
            },
            returns_typed = {
                { name = "result", type = "Issue", description = "Issue object" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            mutating = false
        },
        {
            name = "list",
            path = "jira.issue.list",
            signature = "(project_key, opts)",
            returns_contract = "core.iter",
            yields = "Issue",
            description = "List issues in a project",
            params = {
                { name = "project_key", type = "string", description = "Project key (e.g., 'PROJ')" },
                { name = "opts", type = "table", optional = true, description = "Options: limit, per_page, status, assignee" }
            },
            returns_typed = {
                { name = "iterator", type = "Iterator", description = "Iterator yielding Issue objects" }
            },
            mutating = false
        },
        {
            name = "find",
            path = "jira.issue.find",
            signature = "(query, opts)",
            returns_contract = "core.iter",
            yields = "Issue",
            description = "Search issues using JQL (POST /rest/api/3/search/jql with token pagination)",
            params = {
                { name = "query", type = "string", description = "JQL query string" },
                { name = "opts", type = "table", optional = true, description = "Options: limit, per_page, fields, expand" }
            },
            returns_typed = {
                { name = "iterator", type = "Iterator", description = "Iterator yielding Issue objects" }
            },
            mutating = false
        },
        {
            name = "create",
            path = "jira.issue.create",
            signature = "(data)",
            returns_contract = "core.result",
            description = "Create a new issue using shorthand fields or a native Jira create payload",
            params = {
                { name = "data", type = "table", description = "Either shorthand issue fields or a native Jira create payload: {fields?:table, update?:table, properties?:table}" }
            },
            returns_typed = {
                { name = "result", type = "Issue", description = "Created issue" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            mutating = true
        },
        {
            name = "update",
            path = "jira.issue.update",
            signature = "(key, data, opts)",
            returns_contract = "core.result",
            description = "Update an existing issue (fields/update) and return the refreshed issue",
            params = {
                { name = "key", type = "string", description = "Issue key (e.g., 'PROJ-123')" },
                { name = "data", type = "table", description = "Edit payload: {fields?:table, update?:table, properties?:table, transition?:table, historyMetadata?:table}" },
                { name = "opts", type = "table", optional = true, description = "Options: notify_users, override_screen_security, override_editable_flag, fields, expand" }
            },
            returns_typed = {
                { name = "result", type = "Issue", description = "Updated issue (refreshed)" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            mutating = true
        },
        {
            name = "transition",
            path = "jira.issue.transition",
            signature = "(key, transition_id, opts)",
            returns_contract = "core.result",
            description = "Transition an issue to a different status/workflow state",
            params = {
                { name = "key", type = "string", description = "Issue key (e.g., 'PROJ-123')" },
                { name = "transition_id", type = "string|number", description = "Transition ID to execute" },
                { name = "opts", type = "table", optional = true, description = "Options: comment, fields, resolution" }
            },
            returns_typed = {
                { name = "result", type = "Issue", description = "Transitioned issue (refreshed)" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            mutating = true
        },
        {
            name = "subtasks",
            path = "jira.issue.subtasks",
            signature = "(parent_key, opts)",
            returns_contract = "core.result",
            description = "Get all subtasks of a parent issue",
            params = {
                { name = "parent_key", type = "string", description = "Parent issue key (e.g., 'PROJ-123')" },
                { name = "opts", type = "table", optional = true, description = "Options: fields, expand" }
            },
            returns_typed = {
                { name = "result", type = "Issue[]", description = "Array of subtask issue objects" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            mutating = false
        },
        {
            name = "parent",
            path = "jira.issue.parent",
            signature = "(child_key, opts)",
            returns_contract = "core.result",
            description = "Get the parent issue of a subtask",
            params = {
                { name = "child_key", type = "string", description = "Child/subtask issue key" },
                { name = "opts", type = "table", optional = true, description = "Options: fields, expand" }
            },
            returns_typed = {
                { name = "result", type = "Issue", description = "Parent issue object" },
                { name = "err", type = "core.error|nil", description = "Error if failed (including if issue has no parent)" }
            },
            mutating = false
        },
        {
            name = "hierarchy",
            path = "jira.issue.hierarchy",
            signature = "(issue_key, opts)",
            returns_contract = "core.result",
            description = "Get the full issue hierarchy (parent and children)",
            params = {
                { name = "issue_key", type = "string", description = "Any issue in the hierarchy" },
                { name = "opts", type = "table", optional = true, description = "Options: fields, direction ('up'/'down'/'both'), max_depth" }
            },
            returns_typed = {
                { name = "result", type = "IssueHierarchy", description = "Hierarchy structure with issue, parent, children, ancestors, descendants" },
                { name = "err", type = "core.error|nil", description = "Error if failed" }
            },
            mutating = false
        }
    },
	types = {
		Issue = { shape = "{id?:string, key?:string, self?:string, fields?:table, ...}" },
		IssueHierarchy = { shape = "{issue:Issue, parent?:Issue, children:Issue[], ancestors:Issue[], descendants:Issue[]}" },
	}
}

-- Get issue by key
-- opts: { fields = "summary,status", expand = "changelog" }
function jira.issue.get(issue_key, opts)
    if not issue_key or issue_key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "issue_key is required",
            recoverable = true,
            suggestion = "Provide a valid issue key, e.g., 'PROJ-123'"
        }
    end

    opts = opts or {}
    local query = {}

    if opts.fields then
        query.fields = opts.fields
    end
    if opts.expand then
        query.expand = opts.expand
    end

    local path = "/rest/api/3/issue/" .. issue_key
    return jira._client.request("GET", path, { query = query })
end

-- List issues in a project (uses search internally)
-- opts: { limit, per_page, status, assignee }
function jira.issue.list(project_key, opts)
    if not project_key or project_key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "project_key is required",
            recoverable = true,
            suggestion = "Provide a valid project key, e.g., 'PROJ'"
        }
    end

    opts = opts or {}

    -- Build JQL
    local jql = string.format("project = %s", project_key)
    if opts.status then
        jql = jql .. string.format(" AND status = \"%s\"", opts.status)
    end
    if opts.assignee then
        jql = jql .. string.format(" AND assignee = \"%s\"", opts.assignee)
    end
    jql = jql .. " ORDER BY created DESC"

    return jira.issue.find(jql, {
        limit = opts.limit,
        per_page = opts.per_page,
        fields = opts.fields
    })
end

-- Search issues with JQL
-- Uses /rest/api/3/search/jql with token-based pagination
-- opts: {
--   limit, per_page, fields, expand,
-- }
function jira.issue.find(query, opts)
    if not query or query == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "query (JQL) is required",
            recoverable = true,
            suggestion = "Provide a valid JQL query string, e.g., 'project = PROJ AND status = Done'"
        }
    end

    opts = opts or {}
    local fields = opts.fields or "id,key,summary"

    local auth, err = jira._client.get_auth()
    if err then
        return nil, err
    end

    local cfg = jira._client.get_config()

    local function normalize_fields(value)
        if value == nil then
            return { "id", "key", "summary" }
        end
        if type(value) == "table" then
            return value
        end
        if type(value) == "string" then
            local out = {}
            for part in string.gmatch(value, "[^,]+") do
                local trimmed = (part:gsub("^%s+", ""):gsub("%s+$", ""))
                if trimmed ~= "" then
                    table.insert(out, trimmed)
                end
            end
            if #out == 0 then
                return { "id", "key", "summary" }
            end
            return out
        end

        return { "id", "key", "summary" }
    end

    local body = {
        jql = query,
        fields = normalize_fields(opts.fields or fields),
    }
    if opts.expand then
        body.expand = opts.expand
    end

    return _raw.http.list("POST", cfg.base_url, "/rest/api/3/search/jql", {
        auth = auth,
        query = {},
        headers = {
            ["Accept"] = "application/json",
            ["Content-Type"] = "application/json",
        },
        body = body,
        pagination = {
            kind = "token",
            items_path = "issues",
            token_param = "nextPageToken",
            limit_param = "maxResults",
            next_token_path = "nextPageToken",
            is_last_path = "isLast",
        },
        limit = opts.limit,
        per_page = opts.per_page or 50,
    })
end

-- Internal helper so create payload handling can be unit-tested in readonly mode.
function jira.issue._normalize_create_payload(data)
    if not data or type(data) ~= "table" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "data table is required",
            recoverable = true,
            suggestion = "Provide either shorthand issue fields or a native Jira create payload with fields/update/properties"
        }
    end

    local is_native_payload = data.fields ~= nil or data.update ~= nil or data.properties ~= nil
    local fields = data

    if is_native_payload then
        if data.fields == nil then
            return nil, {
                code = "MISSING_REQUIRED_FIELD",
                message = "data.fields is required when using native Jira create payload",
                recoverable = true,
                suggestion = "Provide { fields = { project = { key = 'PROJ' }, summary = '...', issuetype = { name = 'Task' } }, update = ... }"
            }
        end

        if type(data.fields) ~= "table" then
            return nil, {
                code = "VALIDATION_FAILED",
                message = "data.fields must be a table when using native Jira create payload",
                recoverable = true,
                suggestion = "Provide fields as a table, e.g., { fields = { project = { key = 'PROJ' }, summary = '...', issuetype = { name = 'Task' } } }"
            }
        end

        fields = data.fields
    end

    if not fields.project then
        return nil, {
            code = "MISSING_REQUIRED_FIELD",
            message = (is_native_payload and "data.fields.project" or "data.project") .. " is required",
            recoverable = true,
            suggestion = "Add project field, e.g., {project = {key = 'PROJ'}} or {fields = {project = {key = 'PROJ'}}}"
        }
    end

    if not fields.summary then
        return nil, {
            code = "MISSING_REQUIRED_FIELD",
            message = (is_native_payload and "data.fields.summary" or "data.summary") .. " is required",
            recoverable = true,
            suggestion = "Add summary field either at top level or under fields"
        }
    end

    if not fields.issuetype then
        return nil, {
            code = "MISSING_REQUIRED_FIELD",
            message = (is_native_payload and "data.fields.issuetype" or "data.issuetype") .. " is required",
            recoverable = true,
            suggestion = "Add issuetype field, e.g., {issuetype = {name = 'Bug'}} or {fields = {issuetype = {name = 'Bug'}}}"
        }
    end

    if is_native_payload then
        return data, nil
    end

    return { fields = data }, nil
end

-- Create issue (mutating)
-- data: either shorthand fields { project = { key = "PROJ" }, summary = "...", issuetype = { name = "Bug" }, ... }
--       or a native Jira create payload { fields = {...}, update = {...}, properties = {...} }
function jira.issue.create(data)
    local body, err = jira.issue._normalize_create_payload(data)
    if err then
        return nil, err
    end

    return jira._client.request("POST", "/rest/api/3/issue", { body = body })
end

-- Update issue (mutating)
-- data: Jira edit payload (fields/update/etc)
-- opts: { notify_users, override_screen_security, override_editable_flag, fields, expand }
--
-- Example payload:
-- {
--   fields = { summary = "New summary" },
--   update = { labels = { { add = "triaged" } } }
-- }
function jira.issue.update(key, data, opts)
    -- Validate inputs first (before security check)
    if not key or key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "key is required",
            recoverable = true,
            suggestion = "Provide a valid issue key, e.g., 'PROJ-123'"
        }
    end

    if not data or type(data) ~= "table" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "data table is required",
            recoverable = true,
            suggestion = "Provide a data table with at least one of: fields, update, transition, properties, historyMetadata"
        }
    end

    if data.fields == nil and data.update == nil and data.transition == nil and data.properties == nil and data.historyMetadata == nil then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "data must include at least one of: fields, update, transition, properties, historyMetadata",
            recoverable = true,
            suggestion = "Add at least one field to update, e.g., {fields = {summary = 'New title'}}"
        }
    end

    opts = opts or {}
    local query = {}

    if opts.notify_users ~= nil then
        query.notifyUsers = opts.notify_users
    end
    if opts.override_screen_security ~= nil then
        query.overrideScreenSecurity = opts.override_screen_security
    end
    if opts.override_editable_flag ~= nil then
        query.overrideEditableFlag = opts.override_editable_flag
    end

    local path = "/rest/api/3/issue/" .. key
    local _, err = jira._client.request("PUT", path, { query = query, body = data })
    if err then
        return nil, err
    end

    return jira.issue.get(key, { fields = opts.fields, expand = opts.expand })
end

-- Transition issue to a different workflow state (mutating)
-- opts: { comment, fields, resolution }
function jira.issue.transition(key, transition_id, opts)
    -- Validate inputs first (before security check)
    if not key or key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "key is required",
            recoverable = true,
            suggestion = "Provide a valid issue key, e.g., 'PROJ-123'"
        }
    end

    if not transition_id then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "transition_id is required",
            recoverable = true,
            suggestion = "Provide a valid transition ID (use jira.issue.get to see available transitions)"
        }
    end

    opts = opts or {}

    local body = {
        transition = {
            id = tostring(transition_id)
        }
    }

    -- Add optional comment
    if opts.comment then
        body.update = {
            comment = {
                {
                    add = {
                        body = opts.comment
                    }
                }
            }
        }
    end

    -- Add optional fields (e.g., resolution)
    if opts.fields then
        body.fields = opts.fields
    end

    -- Add resolution if provided separately
    if opts.resolution then
        body.fields = body.fields or {}
        body.fields.resolution = opts.resolution
    end

    local path = "/rest/api/3/issue/" .. key .. "/transitions"
    local _, err = jira._client.request("POST", path, { body = body })
    if err then
        return nil, err
    end

    -- Refresh pattern: get updated issue after transition
    return jira.issue.get(key, { fields = opts.fields })
end

-- Get all subtasks of a parent issue
-- Returns the subtasks array directly from the parent issue's fields
function jira.issue.subtasks(parent_key, opts)
    if not parent_key or parent_key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "parent_key is required",
            recoverable = true,
            suggestion = "Provide a valid parent issue key, e.g., 'PROJ-123'"
        }
    end

    opts = opts or {}

    -- Fetch the parent issue with subtasks field
    local parent, err = jira.issue.get(parent_key, {
        fields = "subtasks," .. (opts.fields or "summary,status,issuetype,parent")
    })

    if err then
        return nil, err
    end

    -- Check if issue has subtasks
    if not parent.fields or not parent.fields.subtasks then
        return {}, nil  -- Empty array if no subtasks field
    end

    local subtasks = parent.fields.subtasks

    -- If we need full issue details, fetch each subtask
    -- The subtasks field contains minimal info, so we fetch full details
    local full_subtasks = {}
    for _, subtask_ref in ipairs(subtasks) do
        local full_subtask, fetch_err = jira.issue.get(subtask_ref.key, opts)
        if fetch_err then
            return nil, fetch_err
        end
        table.insert(full_subtasks, full_subtask)
    end

    return full_subtasks, nil
end

-- Get parent issue of a subtask
function jira.issue.parent(child_key, opts)
    if not child_key or child_key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "child_key is required",
            recoverable = true,
            suggestion = "Provide a valid child/subtask issue key, e.g., 'PROJ-456'"
        }
    end

    opts = opts or {}

    -- Fetch the child issue with parent field
    local child, err = jira.issue.get(child_key, {
        fields = "parent," .. (opts.fields or "summary,status,issuetype")
    })

    if err then
        return nil, err
    end

    -- Check if issue has a parent
    if not child.fields or not child.fields.parent then
        return nil, {
            code = "RESOURCE_NOT_FOUND",
            message = "Issue " .. child_key .. " has no parent",
            context = { issue_key = child_key },
            recoverable = false,
            suggestion = "This issue is not a subtask or does not have a parent issue"
        }
    end

    local parent_key = child.fields.parent.key

    -- Fetch full parent details
    return jira.issue.get(parent_key, opts)
end

-- Get full issue hierarchy
-- opts: { fields, direction = "both" | "up" | "down", max_depth = 10 }
function jira.issue.hierarchy(issue_key, opts)
    if not issue_key or issue_key == "" then
        return nil, {
            code = "VALIDATION_FAILED",
            message = "issue_key is required",
            recoverable = true,
            suggestion = "Provide a valid issue key, e.g., 'PROJ-123'"
        }
    end

    opts = opts or {}
    local direction = opts.direction or "both"
    local max_depth = opts.max_depth or 10

    -- Fetch the main issue
    local issue, err = jira.issue.get(issue_key, {
        fields = "parent,subtasks," .. (opts.fields or "summary,status,issuetype")
    })

    if err then
        return nil, err
    end

    local hierarchy = {
        issue = issue,
        parent = nil,
        children = {},
        ancestors = {},
        descendants = {}
    }

    -- Get parent (upward direction)
    if direction == "up" or direction == "both" then
        if issue.fields and issue.fields.parent then
            local parent, parent_err = jira.issue.parent(issue_key, opts)
            if not parent_err then
                hierarchy.parent = parent

                -- Get ancestors recursively (limit depth)
                local current = parent
                local depth = 1
                while current and depth < max_depth do
                    table.insert(hierarchy.ancestors, current)
                    if current.fields and current.fields.parent then
                        local ancestor, ancestor_err = jira.issue.parent(current.key, opts)
                        if ancestor_err then
                            break
                        end
                        current = ancestor
                        depth = depth + 1
                    else
                        break
                    end
                end
            end
        end
    end

    -- Get children (downward direction)
    if direction == "down" or direction == "both" then
        local subtasks, subtasks_err = jira.issue.subtasks(issue_key, opts)
        if not subtasks_err then
            hierarchy.children = subtasks

            -- Get descendants recursively (limit depth)
            local function get_descendants(parent_subtasks, depth)
                if depth >= max_depth then
                    return parent_subtasks
                end

                local all_descendants = {}
                for _, child in ipairs(parent_subtasks) do
                    table.insert(all_descendants, child)
                    local child_subtasks, child_err = jira.issue.subtasks(child.key, opts)
                    if not child_err and #child_subtasks > 0 then
                        local nested = get_descendants(child_subtasks, depth + 1)
                        for _, desc in ipairs(nested) do
                            table.insert(all_descendants, desc)
                        end
                    end
                end
                return all_descendants
            end

            hierarchy.descendants = get_descendants(subtasks, 1)
        end
    end

    return hierarchy, nil
end
