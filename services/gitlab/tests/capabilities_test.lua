-- Test gitlab service capabilities and basic functionality
-- This test validates the service is properly loaded and has correct schema

test.describe("GitLab Service - Capabilities")

-- Test that gitlab namespace exists
test.assert_not_nil(gitlab, "gitlab namespace should exist")
test.assert_not_nil(gitlab.mr, "gitlab.mr namespace should exist")
test.assert_not_nil(gitlab.pipeline, "gitlab.pipeline namespace should exist")
test.assert_not_nil(gitlab.job, "gitlab.job namespace should exist")
test.assert_not_nil(gitlab.repo, "gitlab.repo namespace should exist")
test.assert_not_nil(gitlab.branch, "gitlab.branch namespace should exist")
test.assert_not_nil(gitlab.commit, "gitlab.commit namespace should exist")

test.describe("GitLab Service - Schema Discovery")

-- Test that schemas are registered
local schemas = ctx_init().namespaces
test.assert_not_nil(schemas.gitlab, "gitlab schemas should be registered")
test.assert_not_nil(schemas.gitlab.mr, "gitlab.mr schema should exist")
test.assert_not_nil(schemas.gitlab.pipeline, "gitlab.pipeline schema should exist")
test.assert_not_nil(schemas.gitlab.job, "gitlab.job schema should exist")
test.assert_not_nil(schemas.gitlab.repo, "gitlab.repo schema should exist")
test.assert_not_nil(schemas.gitlab.branch, "gitlab.branch schema should exist")
test.assert_not_nil(schemas.gitlab.commit, "gitlab.commit schema should exist")

test.describe("GitLab Service - Individual Schema Details")

-- Test gitlab.mr schema
local mr_schema = schema("gitlab.mr")
test.assert_not_nil(mr_schema, "gitlab.mr schema should be retrievable")
test.assert_eq(mr_schema.namespace, "gitlab.mr", "mr schema namespace should be correct")
test.assert_eq(mr_schema.service, "gitlab", "mr schema service should be gitlab")
test.assert_not_nil(mr_schema.functions, "mr schema should have functions")
test.assert(#mr_schema.functions > 0, "mr schema should have at least one function")

-- Test that specific functions exist in schema
local has_get = false
local has_list = false
local has_create = false
local has_update = false

for _, func in ipairs(mr_schema.functions) do
	if func.name == "get" then
		has_get = true
		test.assert_eq(func.guarded, false, "mr.get should not be guarded")
	end
	if func.name == "list" then
		has_list = true
		test.assert_eq(func.guarded, false, "mr.list should not be guarded")
	end
	if func.name == "create" then
		has_create = true
		test.assert_eq(func.guarded, true, "mr.create should be guarded")
	end
	if func.name == "update" then
		has_update = true
		test.assert_eq(func.guarded, true, "mr.update should be guarded")
	end
end

test.assert(has_get, "mr schema should include get function")
test.assert(has_list, "mr schema should include list function")
test.assert(has_create, "mr schema should include create function")
test.assert(has_update, "mr schema should include update function")

test.describe("GitLab Service - Examples")

-- Test that examples are available
local mr_examples = examples("gitlab.mr")
test.assert_not_nil(mr_examples, "gitlab.mr examples should exist")
test.assert(type(mr_examples) == "string", "examples should be a string")
test.assert(#mr_examples > 0, "examples should not be empty")

test.describe("GitLab Service - AI Context")

-- Test that gitlab appears in ai_context (v2.0 compact format)
local context = ctx_init()
test.assert_not_nil(context, "ai_context should return a table")
test.assert_not_nil(context.namespaces, "ai_context should have namespaces field")
test.assert_not_nil(context.namespaces.gitlab, "ai_context should include gitlab")
test.assert_not_nil(context.namespaces.gitlab.mr, "ai_context should include gitlab.mr")
test.assert_not_nil(context.namespaces.gitlab.mr.get, "ai_context should include gitlab.mr.get operation")

test.assert_not_nil(context.discovery, "ai_context should include discovery")
test.assert_not_nil(context.discovery.target_format, "ai_context should include discovery.target_format")
test.assert_eq(context.discovery.target_format.pattern, "<service> | <service>.<resource>", "ai_context should describe discovery target format")

test.describe("GitLab Service - Function Types")

-- Test that functions are actually functions
test.assert_eq(type(gitlab.mr.get), "function", "gitlab.mr.get should be a function")
test.assert_eq(type(gitlab.mr.list), "function", "gitlab.mr.list should be a function")
test.assert_eq(type(gitlab.pipeline.get), "function", "gitlab.pipeline.get should be a function")
test.assert_eq(type(gitlab.job.list), "function", "gitlab.job.list should be a function")

test.describe("GitLab Service - Repo Identifier Normalization")

-- This is a pure path-building check (no network/CLI).
local client = gitlab._get_client()
test.assert_eq(client.project_path(123, ""), "projects/123", "numeric project id should be accepted")
test.assert_eq(client.project_lookup_path("group/project"), "projects/group%2Fproject", "string repo path should be url-encoded for lookup")

test.describe("GitLab Service - Repo Tree")

local repo_schema = schema("gitlab.repo")
test.assert_not_nil(repo_schema, "gitlab.repo schema should exist")

local has_tree = false
for _, func in ipairs(repo_schema.functions) do
	if func.name == "tree" then
		has_tree = true
		test.assert_eq(func.signature, "(repo, opts)", "repo.tree signature should match")
		test.assert_eq(func.guarded, false, "repo.tree should not be guarded")
		test.assert_eq(func.returns_contract, "core.iter", "repo.tree should return iterator contract")
		test.assert_eq(func.yields, "TreeEntry", "repo.tree should yield TreeEntry items")
	end
end

test.assert(has_tree, "repo.tree function should exist in schema")
test.assert_eq(type(gitlab.repo.tree), "function", "gitlab.repo.tree should be a function")
test.assert_not_nil(repo_schema.types.TreeEntry, "TreeEntry type should exist")

test.describe("GitLab Service - Tier 1 Features: MR Discussions")

-- Test MR Discussions schema
local has_discussions = false
local has_discussion = false
local has_discussion_create = false
local has_diff_refs = false

for _, func in ipairs(mr_schema.functions) do
	if func.name == "discussions" then
		has_discussions = true
		test.assert_eq(func.signature, "(repo, iid, opts)", "discussions signature should match")
		test.assert_eq(func.guarded, false, "discussions should not be guarded")
	elseif func.name == "discussion" then
		has_discussion = true
		test.assert_eq(func.signature, "(repo, iid, discussion_id)", "discussion signature should match")
		test.assert_eq(func.guarded, false, "discussion should not be guarded")
	elseif func.name == "discussion_create" then
		has_discussion_create = true
		test.assert_eq(func.signature, "(repo, iid, body, position)", "discussion_create signature should match")
		test.assert_eq(func.guarded, true, "discussion_create should be guarded")
	elseif func.name == "diff_refs" then
		has_diff_refs = true
		test.assert_eq(func.signature, "(repo, iid)", "diff_refs signature should match")
		test.assert_eq(func.guarded, false, "diff_refs should not be guarded")
	end
end

test.assert(has_discussions, "discussions function should exist in schema")
test.assert(has_discussion, "discussion function should exist in schema")
test.assert(has_discussion_create, "discussion_create function should exist in schema")
test.assert(has_diff_refs, "diff_refs function should exist in schema")
test.assert_eq(type(gitlab.mr.discussions), "function", "gitlab.mr.discussions should be a function")
test.assert_eq(type(gitlab.mr.discussion), "function", "gitlab.mr.discussion should be a function")
test.assert_eq(type(gitlab.mr.discussion_create), "function", "gitlab.mr.discussion_create should be a function")
test.assert_eq(type(gitlab.mr.diff_refs), "function", "gitlab.mr.diff_refs should be a function")
test.assert_not_nil(mr_schema.types.DiffPosition, "DiffPosition type should exist")
test.assert_eq(
	mr_schema.types.DiffPosition.shape,
	"{base_sha:string, start_sha:string, head_sha:string, old_path:string, new_path:string, new_line?:number, old_line?:number, position_type?:string}",
	"DiffPosition shape should require both old_path and new_path"
)

test.describe("GitLab Service - Tier 1 Features: Job Play")

-- Test Job Play schema
local job_schema = schema("gitlab.job")
test.assert_not_nil(job_schema, "gitlab.job schema should exist")

local has_play = false
local has_filtering_description = false
local has_artifact_download = false

for _, func in ipairs(job_schema.functions) do
	if func.name == "play" then
		has_play = true
		test.assert_eq(func.signature, "(repo, id)", "play signature should match")
		test.assert_eq(func.guarded, true, "play should be guarded")
	elseif func.name == "list" then
		has_filtering_description = string.match(func.description or "", "filtering") ~= nil
	elseif func.name == "artifact_download" then
		has_artifact_download = true
		test.assert_eq(func.guarded, false, "artifact_download should not be guarded (VFS writes allowed in readonly by policy)")
		test.assert_eq(func.signature, "(repo, id, opts)", "artifact_download signature should match")
	end
end

test.assert(has_play, "play function should exist in schema")
test.assert(has_artifact_download, "artifact_download function should exist in schema")
test.assert(has_filtering_description, "job.list description should mention filtering")
test.assert_eq(type(gitlab.job.play), "function", "gitlab.job.play should be a function")
test.assert_eq(type(gitlab.job.artifact_download), "function", "gitlab.job.artifact_download should be a function")

test.describe("GitLab Service - Tier 1 Features: Pipeline Jobs Filtering")

-- Test Pipeline Jobs Filtering schema
local pipeline_schema = schema("gitlab.pipeline")
test.assert_not_nil(pipeline_schema, "gitlab.pipeline schema should exist")

local has_filtering_in_pipeline = false

for _, func in ipairs(pipeline_schema.functions) do
	if func.name == "jobs" then
		has_filtering_in_pipeline = string.match(func.description or "", "filtering") ~= nil
	end
end

test.assert(has_filtering_in_pipeline, "pipeline.jobs description should mention filtering")
test.assert_eq(type(gitlab.pipeline.jobs), "function", "gitlab.pipeline.jobs should be a function")

test.describe("GitLab Service - v2.0 New Functions")

-- Test new MR actions
local has_merge = false
local has_close = false
local has_reopen = false

for _, func in ipairs(mr_schema.functions) do
	if func.name == "merge" then
		has_merge = true
		test.assert_eq(func.guarded, true, "mr.merge should be guarded")
	elseif func.name == "close" then
		has_close = true
		test.assert_eq(func.guarded, true, "mr.close should be guarded")
	elseif func.name == "reopen" then
		has_reopen = true
		test.assert_eq(func.guarded, true, "mr.reopen should be guarded")
	end
end

test.assert(has_merge, "mr.merge function should exist in schema")
test.assert(has_close, "mr.close function should exist in schema")
test.assert(has_reopen, "mr.reopen function should exist in schema")
test.assert_eq(type(gitlab.mr.merge), "function", "gitlab.mr.merge should be a function")
test.assert_eq(type(gitlab.mr.close), "function", "gitlab.mr.close should be a function")
test.assert_eq(type(gitlab.mr.reopen), "function", "gitlab.mr.reopen should be a function")

-- Test pipeline.merge_request parent lookup
local has_pipeline_mr = false
for _, func in ipairs(pipeline_schema.functions) do
	if func.name == "merge_request" then
		has_pipeline_mr = true
		test.assert_eq(func.guarded, false, "pipeline.merge_request should not be guarded")
	end
end
test.assert(has_pipeline_mr, "pipeline.merge_request function should exist in schema")
test.assert_eq(type(gitlab.pipeline.merge_request), "function", "gitlab.pipeline.merge_request should be a function")

-- Test job.pipeline parent lookup
local has_job_pipeline = false
for _, func in ipairs(job_schema.functions) do
	if func.name == "pipeline" then
		has_job_pipeline = true
		test.assert_eq(func.guarded, false, "job.pipeline should not be guarded")
	end
end
test.assert(has_job_pipeline, "job.pipeline function should exist in schema")
test.assert_eq(type(gitlab.job.pipeline), "function", "gitlab.job.pipeline should be a function")

-- Test search.find (renamed from search.group)
local search_schema = schema("gitlab.search")
test.assert_not_nil(search_schema, "gitlab.search schema should exist")

local has_find = false
for _, func in ipairs(search_schema.functions) do
	if func.name == "find" then
		has_find = true
		test.assert_eq(func.guarded, false, "search.find should not be guarded")
	end
end
test.assert(has_find, "search.find function should exist in schema")
test.assert_eq(type(gitlab.search.find), "function", "gitlab.search.find should be a function")

test.summary()
