-- gitlab/examples/search.lua
-- Usage examples for gitlab.search API

-- Example 1: Find projects by name
-- Set group_id to the GitLab group you want to search.
local search_opts = { group_id = "example-group" }
for project in gitlab.search.find("projects", "sales", search_opts) do
  print(string.format("Project: %s (%s)", project.name, project.path_with_namespace))
  print("  URL:", project.web_url)
  print("  Description:", project.description or "N/A")
end

-- Example 2: Search for code (blobs) with filename filter
-- Useful for finding specific file types or patterns
for blob in gitlab.search.find("blobs", "TODO filename:*.lua", search_opts) do
  print(string.format("Found in: %s (line %d)", blob.path, blob.startline))
  print("  Project ID:", blob.project_id)
  print("  Data snippet:", blob.data:sub(1, 100))
end

-- Example 3: Search merge requests by keyword
-- Find MRs with specific terms in title or description
local mrs, mr_err = helpers.collect(gitlab.search.find("merge_requests", "feature", search_opts), { limit = 10 })
if mr_err then error(mr_err) end
print(string.format("Found %d merge requests", #mrs))
for _, row in ipairs(mrs) do
  local mr = row[1]
  print(string.format("  MR !%d: %s (%s)", mr.iid, mr.title, mr.state))
  print(string.format("    URL: %s", mr.web_url))
end

-- Example 4: Search commits by message
-- Find commits containing specific keywords
for commit in gitlab.search.find("commits", "fix bug", search_opts) do
  print(string.format("Commit: %s", commit.title))
  print(string.format("  Author: %s <%s>", commit.author_name, commit.author_email))
  print(string.format("  Date: %s", commit.created_at))
  print(string.format("  SHA: %s", commit.short_id))
end

-- Example 5: Search issues with filters
-- Find open issues containing specific error messages
for issue in gitlab.search.find("issues", "error", { group_id = "example-group", state = "opened" }) do
  print(string.format("Issue #%d: %s", issue.iid, issue.title))
  print(string.format("  State: %s", issue.state))
  print(string.format("  URL: %s", issue.web_url))
  print(string.format("  Assignee: %s", helpers.get_in(issue, "assignee.name", "Unassigned")))
end

-- Example 6: Search code in specific branch
-- Limit search to a particular branch or tag
for blob in gitlab.search.find("blobs", "class Config", { group_id = "example-group", ref = "main" }) do
  print(string.format("Found in %s (ref: %s)", blob.filename, blob.ref))
  print("  Path:", blob.path)
end

-- Example 7: Search projects with collection and limit
-- Get specific number of results as an array
local projects, projects_err = helpers.collect(gitlab.search.find("projects", "api", search_opts), { limit = 5 })
if projects_err then error(projects_err) end
print(string.format("Found %d projects matching 'api':", #projects))
for i, row in ipairs(projects) do
  local project = row[1]
  print(string.format("%d. %s", i, project.path_with_namespace))
end

-- Example 8: Search milestones
-- Find milestones by title or description
for milestone in gitlab.search.find("milestones", "release", search_opts) do
  print(string.format("Milestone: %s", milestone.title))
  print(string.format("  State: %s", milestone.state))
  if milestone.due_date then
    print(string.format("  Due: %s", milestone.due_date))
  end
end

-- Example 9: Advanced code search with extension filter
-- Find specific file types using extension filter
for blob in gitlab.search.find("blobs", "function extension:py", search_opts) do
  print(string.format("Python file: %s", blob.path))
  print(string.format("  Match at line: %d", blob.startline))
end

-- Example 10: Search with pagination control
-- Use per_page to control results per API call
local count = 0
for mr in gitlab.search.find("merge_requests", "update", { group_id = "example-group", per_page = 50, limit = 100 }) do
  count = count + 1
  print(string.format("%d. MR !%d: %s", count, mr.iid, mr.title))
end
print(string.format("Total processed: %d MRs", count))
