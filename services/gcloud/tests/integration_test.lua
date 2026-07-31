-- GCloud integration tests (requires gcloud CLI installed)
local function test_project_list()
	local projects, err = gcloud.project.list()
	if err then
		if err.code == "CLI_ERROR" or err.code == "AUTH_FAILED" then
			print("SKIP: gcloud CLI not available or not authenticated")
			return
		end
		error("project.list failed: " .. err.message)
	end
	assert(type(projects) == "table", "projects should be a table")
	print("✓ gcloud.project.list returned", #projects, "projects")
end

local function test_capabilities()
	local schema, err = capabilities.schema("gcloud.project")
	assert(err == nil, "schema lookup failed")
	assert(schema.namespace == "gcloud.project", "wrong namespace")
	assert(#schema.functions > 0, "no functions in schema")
	print("✓ capabilities.schema('gcloud.project') works")

end
-- Run tests
test_project_list()
test_capabilities()
print("\n✓ All gcloud integration tests passed")
