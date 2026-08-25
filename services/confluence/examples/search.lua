-- Example: confluence.search
-- Requires: JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN

local results = helpers.collect(
	confluence.search.pages("runbook", {
		limit = 5,
		excerpt = "highlight",
	}),
	{ limit = 5 }
)

for _, row in ipairs(results) do
	print(row.title, row.url)
end
