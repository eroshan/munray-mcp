-- Jira Project Examples
-- Requires: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN

-- Get a project by key
local project, err = jira.project.get("PROJ")
if err then error(err.message or tostring(err)) end
print(project.key, project.name)

-- List projects (iterator)
for p in jira.project.list({ limit = 10 }) do
    print(p.key, p.name)
end
