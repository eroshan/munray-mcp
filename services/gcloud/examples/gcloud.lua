-- Example: gcloud (service-level)
-- Requires: gcloud CLI installed and authenticated

-- Explore available gcloud namespaces/functions
print(json.encode(ctx_init().namespaces.gcloud, true))

-- Common workflow: list projects
local projects, err = gcloud.project.list()
if err then error(err.message) end
for _, p in ipairs(projects or {}) do
	print(p.projectId, p.name)
end
