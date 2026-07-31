-- GitLab integration tests.
--
-- These are opt-in because they depend on live GitLab access and stable resource
-- identifiers. Set the following environment variables to enable them:
--   GITLAB_TEST_REPO
--   GITLAB_TEST_PIPELINE_ID
--   GITLAB_TEST_JOB_ID
-- Optional:
--   GITLAB_TEST_MR_IID

print("=== GitLab Integration Tests ===")

local function fmt_num(n)
	if type(n) == "number" then
		return string.format("%.0f", n)
	end
	return tostring(n)
end

local function parse_required_number(env_name)
	local raw = os.getenv(env_name)
	if raw == nil or raw == "" then
		return nil
	end

	local n = tonumber(raw)
	if n == nil then
		error(env_name .. " must be numeric, got: " .. tostring(raw))
	end

	return n
end

local function main()
	local repo = os.getenv("GITLAB_TEST_REPO")
	local pipeline_id = parse_required_number("GITLAB_TEST_PIPELINE_ID")
	local job_id = parse_required_number("GITLAB_TEST_JOB_ID")
	local mr_iid = parse_required_number("GITLAB_TEST_MR_IID")

	if repo == nil or repo == "" or pipeline_id == nil or job_id == nil then
		print("SKIP: set GITLAB_TEST_REPO, GITLAB_TEST_PIPELINE_ID, and GITLAB_TEST_JOB_ID to run live GitLab integration tests")
		return
	end

	print("Repo:", repo)
	print("Pipeline ID:", fmt_num(pipeline_id))
	print("Job ID:", fmt_num(job_id))
	print("MR IID:", mr_iid and fmt_num(mr_iid) or "(not set)")

	if gitlab then
		print("✓ gitlab global is available")
		print("  - gitlab.mr:", gitlab.mr ~= nil)
		print("  - gitlab.pipeline:", gitlab.pipeline ~= nil)
		print("  - gitlab.job:", gitlab.job ~= nil)
		print("  - gitlab.repo:", gitlab.repo ~= nil)
		print("  - gitlab.branch:", gitlab.branch ~= nil)
	else
		error("gitlab global is NOT available")
	end

	local repo_obj, err = gitlab.repo.get(repo)
	if err then error(err) end
	print("Repository:", repo_obj.name, fmt_num(repo_obj.id), repo_obj.full_path)

	print("\n-- MR.list iterator --")
	local mr_count = 0
	for mr in gitlab.mr.list(repo, { state = "opened", per_page = 5, limit = 5 }) do
		mr_count = mr_count + 1
		print(string.format("  !%d: %s (%s)", mr.iid, mr.title, mr.state))
	end
	print("MRs iterated:", mr_count)

	print("\n-- MR.list with helpers.collect() --")
	local mrs = helpers.collect(gitlab.mr.list(repo, { state = "opened", per_page = 5 }), { limit = 5 })
	print("MRs collected:", #mrs)
	for i, row in ipairs(mrs) do
		local mr = row[1]
		print(string.format("  table %d. !%d: %s (%s)", i, mr.iid, mr.title, mr.state))
	end

	if mr_iid then
		print("\n-- MR.diff --")
		local diffs, derr = gitlab.mr.diff(repo, mr_iid)
		if derr then error(derr) end
		if type(diffs) ~= "table" then
			error("Expected gitlab.mr.diff to return table of diffs")
		end
		print("Files changed:", #diffs)
		if diffs[1] and diffs[1].diff then
			print("First diff length:", #tostring(diffs[1].diff))
		end
	end

	local pipeline, perr = gitlab.pipeline.get(repo, pipeline_id)
	if perr then error(perr) end
	print("Pipeline:", fmt_num(pipeline.id), pipeline.status, pipeline.ref)

	print("\n-- Pipeline.trigger_jobs iterator --")
	local trigger_count = 0
	local ok_triggers, trigger_err = pcall(function()
		for j in gitlab.pipeline.trigger_jobs(repo, pipeline_id, { per_page = 5, limit = 5 }) do
			trigger_count = trigger_count + 1
			print(string.format("  trigger job %s: %s (%s)", fmt_num(j.id), tostring(j.name), tostring(j.status)))
			if j.downstream_pipeline then
				print(string.format("    downstream: %s (%s)", fmt_num(j.downstream_pipeline.id), tostring(j.downstream_pipeline.status)))
			end
		end
	end)
	if not ok_triggers then
		print("Warning: trigger_jobs iteration failed:", tostring(trigger_err))
	end
	print("Trigger jobs iterated:", trigger_count)

	print("\n-- Pipeline.downstream_pipelines iterator --")
	local downstream_count = 0
	local ok_downstream, downstream_err = pcall(function()
		for p in gitlab.pipeline.downstream_pipelines(repo, pipeline_id, { per_page = 5, limit = 5 }) do
			downstream_count = downstream_count + 1
			print(string.format("  downstream pipeline %s: %s", fmt_num(p.id), tostring(p.status)))
		end
	end)
	if not ok_downstream then
		print("Warning: downstream_pipelines iteration failed:", tostring(downstream_err))
	end
	print("Downstream pipelines iterated:", downstream_count)

	print("\n-- Job.list iterator --")
	local job_count = 0
	for job in gitlab.job.list(repo, pipeline_id, { per_page = 5, limit = 5 }) do
		job_count = job_count + 1
		print(string.format("  %s: %s (%s)", fmt_num(job.id), job.name, job.status))
	end
	print("Jobs iterated:", job_count)

	print("\n-- Job.list with helpers.collect() --")
	local jobs = helpers.collect(gitlab.job.list(repo, pipeline_id, { per_page = 5 }), { limit = 5 })
	print("Jobs collected:", #jobs)
	for i, row in ipairs(jobs) do
		local job = row[1]
		print(string.format("  table %d. %s (%s)", i, job.name, job.status))
	end

	local job, gerr = gitlab.job.get(repo, job_id)
	if gerr then error(gerr) end
	print("Job:", fmt_num(job.id), job.name, job.status)

	local log, lerr = gitlab.job.log(repo, job_id)
	if lerr then error(lerr) end
	print("Log length:", #log)

	print("\n-- Branch Operations --")
	local branch_count = 0
	for branch in gitlab.branch.list(repo, { per_page = 5, limit = 5 }) do
		branch_count = branch_count + 1
		print(string.format("  Branch %d: %s (protected: %s, default: %s)", branch_count, branch.name, branch.protected, branch.default))
	end

	print("\n-- Branch.list with helpers.collect() --")
	local branches = helpers.collect(gitlab.branch.list(repo, { per_page = 3 }), { limit = 3 })
	print("Branches (collection mode):", #branches)
	for i, row in ipairs(branches) do
		local branch = row[1]
		print(string.format("  table %d. %s (commit: %s)", i, branch.name, branch.commit.short_id))
	end

	local main_branch, berr = gitlab.branch.get(repo, "master")
	if berr then
		print("Warning: Could not get main branch:", berr)
	else
		print("Main branch:", main_branch.name, "commit:", main_branch.commit.short_id, main_branch.commit.title)
	end

	print("\n-- Test gitlab.repo.branches() delegation --")
	local repo_branches_count = 0
	for branch in gitlab.repo.branches(repo, { limit = 3 }) do
		repo_branches_count = repo_branches_count + 1
		print(string.format("  repo.branches %d: %s", repo_branches_count, branch.name))
	end

	print("\n=== GitLab integration tests completed ===")
end

main()
