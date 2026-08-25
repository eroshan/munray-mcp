-- Jira issue examples (compact)
-- Requires: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN

-- Session vars (persist across calls)
project_key = project_key or "PROJ"
issue_key = issue_key or (project_key .. "-123")
epic_key = epic_key or (project_key .. "-100")

print("=== Jira Issue Examples ===\n")

-- Get + safe access
local issue, err = jira.issue.get(issue_key)
if err then error(err.message or tostring(err)) end
print(issue.key, "-", issue.fields.summary)
print("Type:", helpers.get_in(issue, "fields.issuetype.name", "Unknown"))
print("Status:", helpers.get_in(issue, "fields.status.name", "Unknown"))

-- Find (JQL)
do
    local iter, search_err = jira.issue.find(string.format('project = %s AND status = "Open"', project_key), {
        fields = "summary,status,assignee",
        limit = 3,
    })
    if search_err then error(search_err.message or tostring(search_err)) end

    print("\nOpen issues:")
    for i in iter do
        print(string.format("  %s: %s", i.key, i.fields.summary))
    end
end

-- Hierarchy (down) + subtasks
do
    local h, h_err = jira.issue.hierarchy(epic_key, { direction = "down" })
    if h_err then error(h_err.message or tostring(h_err)) end

    print("\nHierarchy down from", epic_key .. ":")
    print("Root:", h.issue.key, "-", h.issue.fields.summary)
    print("Descendants:", #h.descendants)

    for idx, child in ipairs(h.descendants) do
        if idx > 3 then break end
        print(string.format(
            "  %s [%s]: %s",
            child.key,
            helpers.get_in(child, "fields.issuetype.name", "Unknown"),
            child.fields.summary
        ))
    end

    local subs, s_err = jira.issue.subtasks(issue_key)
    if s_err then error(s_err.message or tostring(s_err)) end
    print("Subtasks:", #subs)
end

-- Field discovery by name (case-insensitive substring)
do
    print("\nField discovery:")
    local field_iter, field_err = jira.field.list({ query = "target", limit = 10 })
    if field_err then error(field_err.message or tostring(field_err)) end

    for field in field_iter do
        print(string.format(
            "  %s (%s) type=%s custom=%s",
            field.name or "<unnamed>",
            field.id or "<no-id>",
            field.type or "unknown",
            tostring(field.custom)
        ))
    end
end

-- Collect iterator -> array (filter + transform)
do
    local iter, search_err = jira.issue.find(string.format("project = %s", project_key), { limit = 30 })
    if search_err then error(search_err.message or tostring(search_err)) end

    local summaries = helpers.collect(iter, {
        filter = function(item)
            local p = helpers.get_in(item, "fields.priority.name")
            return p == "High" or p == "Highest"
        end,
        transform = function(item)
            return string.format("%s: %s", item.key, item.fields.summary)
        end,
    })

    print("\nHigh priority summaries:")
    for idx, s in ipairs(summaries) do
        if idx > 5 then break end
        print("  " .. s)
    end
end

-- Create using shorthand fields
local created, create_err = jira.issue.create({
    project = { key = project_key },
    issuetype = { name = "Task" },
    summary = "simple create",
})
if create_err then error(create_err.message or tostring(create_err)) end
print("\nCreated:", created.key)

-- Create using native Jira payload with update.issuelinks
local linked_issue, linked_err = jira.issue.create({
    fields = {
        project = { key = project_key },
        issuetype = { name = "Task" },
        summary = "linked create",
    },
    update = {
        issuelinks = {
            {
                add = {
                    type = { name = "Blocks" },
                    outwardIssue = { key = issue_key },
                }
            }
        }
    }
})
if linked_err then error(linked_err.message or tostring(linked_err)) end
print("Created linked issue:", linked_issue.key)
