-- Example: List all projects
local projects, list_err = gcloud.project.list()
if list_err then error(list_err.message) end
for _, p in ipairs(projects or {}) do
	print(p.projectId, p.name, p.lifecycleState)
end

-- Example: List projects matching a Lua pattern
local matching, match_err = gcloud.project.list({
	project_pattern = "^prod%-"
})
if match_err then error(match_err.message) end
print("Found", #matching, "matching projects")
