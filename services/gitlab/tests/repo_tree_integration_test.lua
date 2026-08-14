-- GitLab repository tree integration tests.
--
-- Opt in with either:
--   GITLAB_TEST_TREE_REPO=<group/project>
--
-- These tests require live GitLab access and permission to read the repository.
-- Provide an explicitly authorized test repository; no repository is selected by default.

local function enabled_tree_repo()
	local explicit_repo = os.getenv("GITLAB_TEST_TREE_REPO")
	if explicit_repo ~= nil and explicit_repo ~= "" then
		return explicit_repo
	end
	return nil
end

local function err_message(err)
	if type(err) == "table" then
		if err.message ~= nil then
			return tostring(err.message)
		end
		local encoded = json.encode(err)
		if encoded ~= nil and encoded ~= "" then
			return encoded
		end
	end
	return tostring(err)
end

local function must(label, result, err)
	if err then
		error(label .. " failed: " .. err_message(err))
	end
	return result
end

local function find_first_directory(entries)
	for _, row in ipairs(entries) do
		local entry = row[1]
		if type(entry) == "table" and entry.type == "tree" and type(entry.path) == "string" and entry.path ~= "" then
			return entry
		end
	end
	return nil
end

local repo = enabled_tree_repo()
if repo == nil then
	print("SKIP: set GITLAB_TEST_TREE_REPO to run live GitLab repo.tree integration tests")
	return
end

print("=== GitLab repo.tree integration tests ===")
print("Repo:", repo)

local repo_info = must("gitlab.repo.get", gitlab.repo.get(repo))
print("Resolved repo:", repo_info.path_with_namespace or repo_info.full_path or repo_info.name)
print("Default branch:", repo_info.default_branch or "(unknown)")

local root_entries = must("helpers.collect(root tree)", helpers.collect(gitlab.repo.tree(repo, {
	per_page = 20,
}), { limit = 20 }))

assert(type(root_entries) == "table", "root tree should materialize to a table")
assert(#root_entries > 0, "expected at least one root tree entry")
print("✓ root tree returned", #root_entries, "entries")

local first = root_entries[1][1]
assert(type(first.name) == "string" and first.name ~= "", "tree entry should include non-empty name")
assert(type(first.path) == "string" and first.path ~= "", "tree entry should include non-empty path")
assert(type(first.type) == "string" and first.type ~= "", "tree entry should include non-empty type")
print("✓ first root entry:", first.path, "(" .. first.type .. ")")

local dir_entry = find_first_directory(root_entries)
if dir_entry == nil then
	print("SKIP: root listing did not include a directory entry; skipping path and recursive checks")
	print("\n✓ GitLab repo.tree integration tests passed")
	return
end

local child_entries = must("helpers.collect(path tree)", helpers.collect(gitlab.repo.tree(repo, {
	path = dir_entry.path,
	per_page = 20,
}), { limit = 20 }))

assert(type(child_entries) == "table", "path-scoped tree should materialize to a table")
assert(#child_entries > 0, "expected at least one child tree entry under " .. dir_entry.path)
print("✓ path tree for", dir_entry.path, "returned", #child_entries, "entries")

local recursive_entries = must("helpers.take(recursive tree)", helpers.take(gitlab.repo.tree(repo, {
	path = dir_entry.path,
	recursive = true,
	per_page = 20,
}), 20))

assert(type(recursive_entries) == "table", "recursive tree should materialize to a table")
assert(#recursive_entries > 0, "expected recursive tree results under " .. dir_entry.path)
print("✓ recursive tree for", dir_entry.path, "returned", #recursive_entries, "entries")

print("\n✓ GitLab repo.tree integration tests passed")
