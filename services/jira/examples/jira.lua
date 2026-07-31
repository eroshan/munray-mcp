-- Example: Jira (service-level)
-- Requires: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN

project_key = project_key or "PROJ"
issue_key = issue_key or (project_key .. "-123")

print("=== Jira Basic Operations ===\n")

-- Get a single issue
print("1. Getting issue...")
local issue, get_err = jira.issue.get(issue_key)
if get_err then
    print("  Error:", get_err.message or get_err)
else
    print("  Key:", issue.key)
    print("  Summary:", helpers.get_in(issue, "fields.summary", "<missing>"))
    print("  Status:", helpers.get_in(issue, "fields.status.name", "Unknown"))
end

-- Search for issues
print("\n2. Searching for open issues...")
local iter, search_err = jira.issue.find(string.format('project = %s AND status = "Open"', project_key), {
    limit = 5,
    fields = "summary,status",
})
if search_err then
    print("  Error:", search_err.message or search_err)
else
    local count = 0
    for search_result in iter do
        count = count + 1
        print(string.format("  %s: %s", search_result.key, helpers.get_in(search_result, "fields.summary", "<missing>")))
    end
    print(string.format("  (showing %d issues)", count))
end

-- Discover field ids by name
print("\n3. Discovering fields...")
local field_iter, field_err = jira.field.list({ query = "target", limit = 5 })
if field_err then
    print("  Error:", field_err.message or field_err)
else
    for field in field_iter do
        print(string.format("  %s (%s) type=%s", field.name or "<unnamed>", field.id or "<no-id>", field.type or "unknown"))
    end
end
