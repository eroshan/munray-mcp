-- preload/gitlab/init.lua
-- GitLab namespace setup

gitlab = {
	mr = {},
	pipeline = {},
	job = {},
	repo = {},
	commit = {},
	branch = {},
	search = {},
}

gitlab.__intro = [[
Use this service for GitLab merge requests, pipelines, jobs, and repositories.
Prefer capability discovery before calling service functions, and narrow the scope to the relevant project whenever possible.
]]

gitlab.__allowed_cli_commands = { "glab" }

gitlab.__schema = {
	namespace = "gitlab",
	service = "gitlab",
	description = "GitLab REST API client (service pack root).",
	functions = {},
	resources = { "gitlab.mr", "gitlab.pipeline", "gitlab.job", "gitlab.repo", "gitlab.commit", "gitlab.branch", "gitlab.search" },
}

-- Capture private client module (loaded by module loader before resource files)
-- This will be set by _client.lua which loads first alphabetically
-- Store as local upvalue so resource files can access it via closure
-- The global _gitlab_client will be cleaned up after init
local client = nil

-- Helper function to get client (will be called by resource files before client is loaded)
-- This defers the capture until first use
local function get_client()
	if client == nil then
		client = _gitlab_client
		-- Clean up global after first capture
		_gitlab_client = nil
	end
	return client
end

-- Export client getter for resource files to use
-- Resource files will capture this as an upvalue
gitlab._get_client = get_client

local service_errors = nil

local function get_errors()
	if service_errors == nil then
		service_errors = gitlab._errors
	end
	return service_errors
end

gitlab._get_errors = get_errors
