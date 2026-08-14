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
mr_iid = 123

-- Inspect schema when you need signatures or return contracts
local mr_schema, schema_err = capabilities.schema("gitlab.mr")
if schema_err then error(schema_err) end
print("gitlab.mr functions:", #mr_schema.functions)

-- Get a single MR (temporary variables with 'local')
local mr, get_err = gitlab.mr.get(repo, mr_iid)
if get_err then error(get_err) end
print(mr.title, mr.state)

-- List open MRs via iterator (memory-efficient for large datasets)
for m in gitlab.mr.list(repo, { state = "opened", per_page = 5 }) do
    print(m.iid, m.title)
end

-- Collect MRs into array (check err explicitly)
local mrs, list_err = helpers.collect(gitlab.mr.list(repo, { state = "opened", limit = 5 }))
if list_err then error(list_err) end
print("Found", #mrs, "MRs")
for _, row in ipairs(mrs) do
    local m = row[1]
    print(m.iid, m.title)
end

-- Collect with filter and transform
local urgent_titles, urgent_err = helpers.collect(gitlab.mr.list(repo, { state = "opened" }), {
    limit = 10,
    filter = function(row)
        local item = row[1]
        return item.labels and helpers.contains(table.concat(item.labels, ","), "urgent")
    end,
    transform = function(row)
        local item = row[1]
        return { item.title }
    end
})
if urgent_err then error(urgent_err) end
print("Urgent MRs:", table.concat(urgent_titles, ", "))

-- Create MR (requires guarded mode, reuses session vars)
local created_mr, create_err = gitlab.mr.create(repo, {
    source_branch = "feature-x",
    target_branch = "main",
    title = "Add feature X",
    description = "Implements feature X",
    labels = {"enhancement"}
})
if create_err then error(create_err) end
print("Created:", created_mr.web_url)

-- Update MR (requires guarded mode)
local updated_mr, update_err = gitlab.mr.update(repo, mr_iid, {
    title = "Updated title",
    labels = {"bug", "urgent"}
})
if update_err then error(update_err) end
print("Updated:", updated_mr.web_url)

-- Approve MR (requires guarded mode)
local approved_mr, approve_err = gitlab.mr.approve(repo, mr_iid)
if approve_err then error(approve_err) end
print("Approved:", approved_mr.web_url)

-- Merge MR (requires guarded mode)
local merged_mr, merge_err = gitlab.mr.merge(repo, mr_iid, {
    delete_source_branch = true,
    squash = true,
    merge_when_pipeline_succeeds = true
})
if merge_err then error(merge_err) end
print("Merged:", merged_mr.web_url)

-- Close MR (requires guarded mode)
local closed_mr, close_err = gitlab.mr.close(repo, 456)
if close_err then error(close_err) end
print("Closed:", closed_mr.web_url)

-- Reopen MR (requires guarded mode)
local reopened_mr, reopen_err = gitlab.mr.reopen(repo, 456)
if reopen_err then error(reopen_err) end
print("Reopened:", reopened_mr.web_url)

-- Get pipelines for MR's source branch (iterator)
for pipeline in gitlab.mr.pipelines(repo, mr_iid) do
    print(pipeline.id, pipeline.status)
end

-- Get MR diffs (table of per-file diff objects)
local diffs, diff_err = gitlab.mr.diff(repo, mr_iid)
if diff_err then error(diff_err) end
print("Files changed:", #diffs)
for i, d in ipairs(diffs) do
    print(string.format("%d. %s -> %s (new:%s renamed:%s deleted:%s too_large:%s)",
        i,
        tostring(d.old_path),
        tostring(d.new_path),
        tostring(d.new_file),
        tostring(d.renamed_file),
        tostring(d.deleted_file),
        tostring(d.too_large)
    ))
end

-- Print the first file diff (can be large)
if diffs[1] and diffs[1].diff then
    print(diffs[1].diff)
end

-- ============================================================================
-- Posting inline code review comments (DiffNotes)
-- ============================================================================
-- gitlab.mr.discussion_create posts a comment attached to a specific file line.
-- It internally uses `glab api --input <json_file>` because -F/-f with bracket
-- notation produces a non-positioned DiscussionNote (the position silently fails
-- to attach). Requires guarded mode.

-- 1. Get the diff_refs triple (base_sha/start_sha/head_sha) for the MR.
local refs, refs_err = gitlab.mr.diff_refs(repo, mr_iid)
if refs_err then error(refs_err) end

-- 2. Post a single inline comment on a changed/added line.
--    Pass both old_path and new_path; for non-renamed files they are usually identical.
local note, note_err = gitlab.mr.discussion_create(repo, mr_iid,
    "Consider extracting this into a helper for readability.",
    {
        base_sha = refs.base_sha,
        start_sha = refs.start_sha,
        head_sha = refs.head_sha,
        old_path = "src/main.go",
        new_path = "src/main.go",
        new_line = 42,
    }
)
if note_err then error(note_err) end
print("Posted inline comment as discussion:", note.id)

-- 3. Comment on a removed line. Pass both old_path and new_path.
--    For non-renamed files they are usually identical.
local removed_note, removed_err = gitlab.mr.discussion_create(repo, mr_iid,
    "Why was this check dropped?",
    {
        base_sha = refs.base_sha,
        start_sha = refs.start_sha,
        head_sha = refs.head_sha,
        old_path = "src/main.go",
        new_path = "src/main.go",
        old_line = 17,
    }
)
if removed_err then error(removed_err) end
print("Posted comment on removed line:", removed_note.id)

-- 4. Walk the MR diff and post a batch review.
local review = {
    { path = "src/main.go", line = 42, body = "Extract this branch into a helper." },
    { path = "src/util.go", line = 7,  body = "Nit: this constant is unused." },
}
for _, item in ipairs(review) do
    local _, post_err = gitlab.mr.discussion_create(repo, mr_iid, item.body, {
        base_sha = refs.base_sha,
        start_sha = refs.start_sha,
        head_sha = refs.head_sha,
        old_path = item.path,
        new_path = item.path,
        new_line = item.line,
    })
    if post_err then
        print("Failed to post comment on", item.path, item.line, post_err.message or post_err)
    end
end
