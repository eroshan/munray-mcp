-- ============================================================================
-- Variable Scoping Best Practices
-- ============================================================================
-- SESSION VARIABLES (persist across calls): repo = "value"
-- TEMPORARY VARIABLES (one-time use): local result, err = func()
--
-- Common mistake: Using 'local' for values you want to reuse later
-- ============================================================================

-- Session-persisted configuration (no 'local')
repo = "group/project"
sha = "abcdef123" -- pick a real commit SHA

-- Fetch a single commit
local commit, get_err = gitlab.commit.get(repo, sha)
if get_err then error(get_err) end
print(commit.id, commit.title)

-- Iterate commits (default iterator mode)
for c in gitlab.commit.list(repo, { ref_name = "main", per_page = 5, limit = 5 }) do
    print(c.id, c.author_name, c.title)
end

-- Collect commits using helpers.collect()
local commits, list_err = helpers.collect(gitlab.commit.list(repo, { ref_name = "main", per_page = 5 }), { limit = 5 })
if list_err then error(list_err) end
print("Collected", #commits, "commits")
for _, row in ipairs(commits) do
    local c = row[1]
    print(c.id, c.title)
end

-- Fetch a commit diff (JSON array of file diffs)
local diff_items, diff_err = gitlab.commit.diff(repo, sha)
if diff_err then error(diff_err) end
print("diff files:", #diff_items)
