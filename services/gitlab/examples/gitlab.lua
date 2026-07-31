-- Example: GitLab (service-level)
-- Typical environment vars for HTTP-based packs:
--   GITLAB_BASE_URL, GITLAB_TOKEN
--
-- Persist values you want to reuse across calls by assigning without 'local'.

repo = "group/project"

-- Discover available namespaces/functions
local gitlab_schema, gitlab_schema_err = capabilities.schema("gitlab")
if gitlab_schema_err then error(gitlab_schema_err) end
print(json.encode(gitlab_schema, true))

-- Inspect a specific namespace when examples do not cover what you need
local repo_schema, repo_schema_err = capabilities.schema("gitlab.repo")
if repo_schema_err then error(repo_schema_err) end
print("gitlab.repo functions:", #repo_schema.functions)

-- Common workflow: list merge requests
for mr in gitlab.mr.list(repo, { state = "opened", limit = 5 }) do
	print(mr.iid, mr.title)
end

-- Fetch a repository file when you need exact contents from the default branch
local repo_info, repo_info_err = gitlab.repo.get(repo)
if repo_info_err then error(repo_info_err) end

local ref = repo_info.default_branch or "main"
local ci_config, file_err = gitlab.repo.file(repo, ".gitlab-ci.yml", ref)
if file_err then error(file_err) end
print(ci_config:sub(1, 200))
