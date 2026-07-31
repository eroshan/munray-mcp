-- Example: Confluence (service-level)
-- Typical environment vars for HTTP-based packs:
--   JIRA_BASE_URL
--   JIRA_EMAIL, JIRA_API_TOKEN

-- Explore available Confluence namespaces/functions
print(json.encode(capabilities.schemas({ namespace = "confluence" }), true))

-- Common workflow: fetch a page
local page, err = confluence.page.get("123456")
if err then
	print("Error:", err.message)
	return
end
print(page.id, page.title)
