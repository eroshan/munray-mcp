-- Example: GitLab Branch Operations
-- This demonstrates creating, getting, listing, and deleting branches

-- Set the repository (persist across calls)
repo = "example-group/example-project"

-- Example 1: Create a feature branch
print("=== Example 1: Create a branch ===")
local branch, create_err = gitlab.branch.create(repo, {
  name = "feature/munray-test",
  ref = "main"
})
if create_err then
  print("Error creating branch:", create_err)
  if type(create_err) == "table" then
    print("Error code:", create_err.code)
    print("Error message:", create_err.message)
  end
else
  print("Created branch:", branch.name)
  print("From commit:", branch.commit.short_id, "-", branch.commit.title)
  print("Protected:", branch.protected)
end

-- Example 2: Get branch details
print("\n=== Example 2: Get branch details ===")
local main_branch, get_err = gitlab.branch.get(repo, "main")
if get_err then
  print("Error getting branch:", get_err)
else
  print("Branch:", main_branch.name)
  print("Default:", main_branch.default)
  print("Protected:", main_branch.protected)
  print("Latest commit:", main_branch.commit.short_id)
  print("Commit title:", main_branch.commit.title)
  print("Author:", main_branch.commit.author_name)
end

-- Example 3: List branches (iterator mode - default)
print("\n=== Example 3: List branches (iterator) ===")
local count = 0
for br in gitlab.branch.list(repo, { search = "feature", limit = 5 }) do
  count = count + 1
  print(count .. ".", br.name, "-", br.commit.short_id)
end

-- Example 4: List branches (with collect)
print("\n=== Example 4: List branches (collection) ===")
local branches, list_err = helpers.collect(gitlab.branch.list(repo, { per_page = 5 }), { limit = 10 })
if list_err then
  print("Error listing branches:", list_err)
else
  print("Found", #branches, "branches")
  for i, row in ipairs(branches) do
    local br = row[1]
    print(i .. ".", br.name, "(protected:", br.protected .. ")")
  end
end

-- Example 5: Delete a branch (guarded operation)
print("\n=== Example 5: Delete a branch ===")
local _success, delete_err = gitlab.branch.delete(repo, "feature/old-branch")
if delete_err then
  print("Error deleting branch:", delete_err)
  if type(delete_err) == "table" and delete_err.code == "NOT_FOUND" then
    print("Branch doesn't exist - that's okay")
  end
else
  print("Branch deleted successfully")
end

-- Example 6: Create and delete workflow
print("\n=== Example 6: Create and delete workflow ===")
local test_branch = "test/munray-" .. os.time()
print("Creating temporary branch:", test_branch)

local new_branch, create_temp_err = gitlab.branch.create(repo, {
  name = test_branch,
  ref = "main"
})
if create_temp_err then
  print("Failed to create:", create_temp_err)
else
  print("Created:", new_branch.name)

  -- Verify it exists
  local fetched, verify_err = gitlab.branch.get(repo, test_branch)
  if fetched then
    print("Verified branch exists:", fetched.name)

    -- Clean up: delete it
    local delete_success, cleanup_err = gitlab.branch.delete(repo, test_branch)
    if delete_success then
      print("Cleaned up: deleted", test_branch)
    else
      print("Failed to delete:", cleanup_err)
    end
  else
    print("Failed to verify:", verify_err)
  end
end

-- Example 7: Handle special characters in branch names
print("\n=== Example 7: Special characters in branch names ===")
-- Branch names with slashes are common (e.g., feature/foo, bugfix/bar)
local special_branch, special_err = gitlab.branch.get(repo, "feature/some-feature")
if special_err then
  if type(special_err) == "table" and special_err.code == "NOT_FOUND" then
    print("Branch 'feature/some-feature' not found (expected)")
  else
    print("Error:", special_err)
  end
else
  print("Found branch with slash:", special_branch.name)
end
