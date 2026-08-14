-- preload/gitlab/mr.lua
-- MergeRequest stateless API (no object wrapping)

-- Capture client from init (will be available when this executes)
local client = gitlab._get_client()
local get_errors = gitlab._get_errors

local function errx()
	return get_errors()
end

gitlab.mr.__schema = {
	namespace = "gitlab.mr",
	service = "gitlab",
	functions = {
		{
			name = "get",
			signature = "(repo, iid)",
			returns_contract = "core.result",
			guarded = false,
			description = "Fetch a single merge request by IID",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "list",
			signature = "(repo, opts)",
			returns_contract = "core.iter",
			yields = "MergeRequest",
			guarded = false,
			description = "List merge requests for a repository (returns iterator; use helpers.collect() to materialize to array)",
			params = { { name = "repo", type = "string|number" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "diff",
			signature = "(repo, iid, opts)",
			returns_contract = "core.result",
			guarded = false,
			description = "List per-file diffs for a merge request.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "iid", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options: unidiff" },
			},
			returns_typed = {
				{ name = "result", type = "MRFileDiff[]", schema = "MRFileDiff[] where MRFileDiff={old_path:string,new_path:string,diff:string,new_file:boolean,renamed_file:boolean,deleted_file:boolean,too_large:boolean, ...}" },
				{ name = "err", type = "core.error|nil" }
			},
		},
		{
			name = "create",
			signature = "(repo, data)",
			returns_contract = "core.result",
			guarded = true,
			description = "Create a new merge request",
			params = { { name = "repo", type = "string|number" }, { name = "data", type = "table" } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "update",
			signature = "(repo, iid, data, opts)",
			returns_contract = "core.result",
			guarded = true,
			description = "Update merge request fields by IID",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" }, { name = "data", type = "table" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "approve",
			signature = "(repo, iid)",
			returns_contract = "core.result",
			guarded = true,
			description = "Approve a merge request by IID",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "merge",
			signature = "(repo, iid, opts)",
			returns_contract = "core.result",
			guarded = true,
			description = "Merge a merge request by IID",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "close",
			signature = "(repo, iid)",
			returns_contract = "core.result",
			guarded = true,
			description = "Close a merge request by IID",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "reopen",
			signature = "(repo, iid)",
			returns_contract = "core.result",
			guarded = true,
			description = "Reopen a merge request by IID",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" } },
			returns_typed = { { name = "result", type = "MergeRequest" }, { name = "err", type = "core.error|nil" } },
		},
		{
			name = "pipelines",
			signature = "(repo, iid, opts)",
			returns_contract = "core.iter",
			yields = "Pipeline",
			guarded = false,
			description = "List pipelines for a merge request's source branch (convenience wrapper for gitlab.pipeline.list)",
			params = { { name = "repo", type = "string|number" }, { name = "iid", type = "number" }, { name = "opts", type = "table", optional = true } },
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "discussions",
			signature = "(repo, iid, opts)",
			returns_contract = "core.iter",
			yields = "Discussion",
			guarded = false,
			description = "List all discussions (comments/review threads) for a merge request (returns iterator; use helpers.collect() to materialize to array)",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "iid", type = "number" },
				{ name = "opts", type = "table", optional = true, description = "Options: per_page, sort ('asc'/'desc')" }
			},
			returns_typed = { { name = "iterator", type = "Iterator" } },
		},
		{
			name = "discussion",
			signature = "(repo, iid, discussion_id)",
			returns_contract = "core.result",
			guarded = false,
			description = "Fetch a single discussion by ID",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "iid", type = "number" },
				{ name = "discussion_id", type = "string" }
			},
			returns_typed = {
				{ name = "result", type = "Discussion" },
				{ name = "err", type = "core.error|nil" }
			},
		},
		{
			name = "discussion_create",
			signature = "(repo, iid, body, position)",
			returns_contract = "core.result",
			guarded = true,
			description = "Create an inline code review comment (DiffNote) attached to a specific file line in a merge request. Use gitlab.mr.diff_refs() to get the required base_sha/start_sha/head_sha. position.old_path and position.new_path are both required and must match the file path before/after the change. For added/changed lines set position.new_line; for removed lines set position.old_line.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "iid", type = "number" },
				{ name = "body", type = "string", description = "Comment text" },
				{ name = "position", type = "DiffPosition", description = "Position descriptor: { base_sha, start_sha, head_sha, old_path, new_path, new_line?, old_line?, position_type? }" },
			},
			returns_typed = {
				{ name = "result", type = "Discussion" },
				{ name = "err", type = "core.error|nil" }
			},
		},
		{
			name = "diff_refs",
			signature = "(repo, iid)",
			returns_contract = "core.result",
			guarded = false,
			description = "Convenience helper that returns the {base_sha, start_sha, head_sha} triple required to build a DiffPosition for gitlab.mr.discussion_create.",
			params = {
				{ name = "repo", type = "string|number" },
				{ name = "iid", type = "number" }
			},
			returns_typed = {
				{ name = "result", type = "DiffRefs" },
				{ name = "err", type = "core.error|nil" }
			},
		},
	},
	types = {
		MergeRequest = { shape = "{id:number, iid:number, title:string, state?:string, web_url?:string, author?:table, ...}" },
		Pipeline = { shape = "{id:number, status?:string, ref?:string, sha?:string, web_url?:string, ...}" },
		Discussion = { shape = "{id:string, individual_note?:boolean, notes?:table, ...}" },
		MRFileDiff = { shape = "{old_path:string, new_path:string, diff?:string, new_file?:boolean, renamed_file?:boolean, deleted_file?:boolean, too_large?:boolean, ...}" },
		DiffRefs = { shape = "{base_sha:string, start_sha:string, head_sha:string}" },
		DiffPosition = { shape = "{base_sha:string, start_sha:string, head_sha:string, old_path:string, new_path:string, new_line?:number, old_line?:number, position_type?:string}" },
	},
}

-- gitlab.mr.get(repo, iid) -> table
function gitlab.mr.get(repo, iid)
	return client.request_json("GET", repo, "merge_requests/" .. iid, nil, nil)
end

-- gitlab.mr.list(repo, opts) -> iterator
-- Always returns iterator; use helpers.collect() to materialize to array
function gitlab.mr.list(repo, opts)
	opts = opts or {}

	local query = {}
	if opts.state ~= nil and opts.state ~= "all" then
		query.state = opts.state
	end
	if opts.author ~= nil then
		query.author_username = opts.author
	end
	if opts.labels ~= nil then
		if type(opts.labels) == "table" then
			query.labels = table.concat(opts.labels, ",")
		else
			query.labels = opts.labels
		end
	end

	return client.list(repo, "merge_requests", query, opts)
end

-- gitlab.mr.diff(repo, iid, opts?) -> table
-- Returns a list of per-file diff objects.
function gitlab.mr.diff(repo, iid, opts)
	opts = opts or {}

	local query = {}
	if opts.unidiff ~= nil then query.unidiff = opts.unidiff end

	local diffs = {}
	local ok, iter_err = pcall(function()
		-- Pagination is intentionally handled internally so callers don't need to know it exists.
		local iter = client.list(repo, "merge_requests/" .. iid .. "/diffs", query, { per_page = 100 })
		for d in iter do
			table.insert(diffs, d)
		end
	end)

	if not ok then
		return nil, errx().from_upstream(iter_err, {
			kind = "list",
			operation = "gitlab.mr.diff",
			public_context = { repo = repo, iid = iid },
		})
	end

	return diffs, nil
end

-- gitlab.mr.create(repo, data) -> table
function gitlab.mr.create(repo, data)
	local body = {
		source_branch = data.source_branch,
		target_branch = data.target_branch,
		title = data.title,
	}
	if data.description ~= nil then body.description = data.description end
	if data.assignee_id ~= nil then body.assignee_id = data.assignee_id end
	if data.labels ~= nil then
		if type(data.labels) == "table" then
			body.labels = table.concat(data.labels, ",")
		else
			body.labels = data.labels
		end
	end

	return client.request_json("POST", repo, "merge_requests", nil, body)
end

-- gitlab.mr.update(repo, iid, data, opts) -> table
function gitlab.mr.update(repo, iid, data, opts) -- luacheck: no unused args
	local body = {}
	if data.title ~= nil then body.title = data.title end
	if data.description ~= nil then body.description = data.description end
	if data.state_event ~= nil then body.state_event = data.state_event end
	if data.labels ~= nil then
		if type(data.labels) == "table" then
			body.labels = table.concat(data.labels, ",")
		else
			body.labels = data.labels
		end
	end

	return client.request_json("PUT", repo, "merge_requests/" .. iid, nil, body)
end

-- gitlab.mr.approve(repo, iid) -> table
function gitlab.mr.approve(repo, iid)
	local _result, err = client.request_json("POST", repo, "merge_requests/" .. iid .. "/approve", nil, {})
	if err then return nil, err end
	-- Refresh pattern
	return client.request_json("GET", repo, "merge_requests/" .. iid, nil, nil)
end

-- gitlab.mr.merge(repo, iid, opts) -> table
function gitlab.mr.merge(repo, iid, opts)
	opts = opts or {}
	local body = {}
	if opts.delete_source_branch ~= nil then body.should_remove_source_branch = opts.delete_source_branch end
	if opts.squash ~= nil then body.squash = opts.squash end
	if opts.merge_when_pipeline_succeeds ~= nil then body.merge_when_pipeline_succeeds = opts.merge_when_pipeline_succeeds end

	local _result, err = client.request_json("PUT", repo, "merge_requests/" .. iid .. "/merge", nil, body)
	if err then return nil, err end
	-- Refresh pattern
	return client.request_json("GET", repo, "merge_requests/" .. iid, nil, nil)
end

-- gitlab.mr.close(repo, iid) -> table
function gitlab.mr.close(repo, iid)
	local body = { state_event = "close" }
	return client.request_json("PUT", repo, "merge_requests/" .. iid, nil, body)
end

-- gitlab.mr.reopen(repo, iid) -> table
function gitlab.mr.reopen(repo, iid)
	local body = { state_event = "reopen" }
	return client.request_json("PUT", repo, "merge_requests/" .. iid, nil, body)
end

-- gitlab.mr.pipelines(repo, iid, opts) -> iterator
-- Always returns iterator; use helpers.collect() to materialize to array
function gitlab.mr.pipelines(repo, iid, opts)
	-- Get MR details to find source branch
	local mr, err = gitlab.mr.get(repo, iid)
	if err then
		error(errx().from_upstream(err, {
			kind = "list",
			operation = "gitlab.mr.pipelines",
			public_context = { repo = repo, iid = iid },
		}), 0)
	end

	opts = opts or {}
	opts.ref = opts.ref or mr.source_branch
	return gitlab.pipeline.list(repo, opts)
end

-- gitlab.mr.discussions(repo, iid, opts) -> iterator
-- Returns iterator over discussion objects; use helpers.collect() to materialize to array
function gitlab.mr.discussions(repo, iid, opts)
	opts = opts or {}

	local query = {}
	if opts.sort ~= nil then
		query.sort = opts.sort
	end

	return client.list(repo, "merge_requests/" .. iid .. "/discussions", query, opts)
end

-- gitlab.mr.discussion(repo, iid, discussion_id) -> table
-- Fetch a single discussion by ID
function gitlab.mr.discussion(repo, iid, discussion_id)
	return client.request_json("GET", repo, "merge_requests/" .. iid .. "/discussions/" .. discussion_id, nil, nil)
end

-- gitlab.mr.diff_refs(repo, iid) -> {base_sha, start_sha, head_sha}, err
-- Convenience helper. The MR object includes diff_refs already; this just narrows it.
function gitlab.mr.diff_refs(repo, iid)
	local mr, err = gitlab.mr.get(repo, iid)
	if err then return nil, err end
	if type(mr.diff_refs) ~= "table" then
		return nil, {
			code = "MISSING_DIFF_REFS",
			message = "merge request response does not include diff_refs",
			context = { iid = iid },
			recoverable = false,
		}
	end
	return {
		base_sha = mr.diff_refs.base_sha,
		start_sha = mr.diff_refs.start_sha,
		head_sha = mr.diff_refs.head_sha,
	}, nil
end

-- Internal: invariants for a DiffPosition table.
local function validate_diff_position(position)
	if type(position) ~= "table" then
		return { code = "INVALID_POSITION", message = "position must be a table", recoverable = false }
	end
	for _, field in ipairs({ "base_sha", "start_sha", "head_sha", "old_path", "new_path" }) do
		if type(position[field]) ~= "string" or position[field] == "" then
			return { code = "INVALID_POSITION", message = "position." .. field .. " is required (string)", recoverable = false }
		end
	end
	-- For modified files commenting on changed/added lines: set new_line.
	-- For modified files commenting on removed lines: set old_line.
	-- Callers must always pass both old_path and new_path; for non-renamed files they are usually identical.
	if position.new_line == nil and position.old_line == nil then
		return { code = "INVALID_POSITION", message = "position.new_line or position.old_line must be set", recoverable = false }
	end
	return nil
end

-- gitlab.mr.discussion_create(repo, iid, body, position) -> Discussion, err
--
-- Posts an inline code review comment (DiffNote) attached to a specific file line.
-- Implements the project's documented rule: glab api with JSON body via --input,
-- because -F/-f with bracket notation creates a non-positioned DiscussionNote.
function gitlab.mr.discussion_create(repo, iid, body, position)
	if type(body) ~= "string" or body == "" then
		return nil, { code = "INVALID_BODY", message = "body must be a non-empty string", recoverable = false }
	end
	local pos_err = validate_diff_position(position)
	if pos_err then return nil, pos_err end

	-- Defaults per the documented rule: position_type=text.
	-- old_path/new_path are validated above and passed through verbatim.
	local payload_position = {
		base_sha = position.base_sha,
		start_sha = position.start_sha,
		head_sha = position.head_sha,
		position_type = position.position_type or "text",
		old_path = position.old_path,
		new_path = position.new_path,
	}
	if position.new_line ~= nil then payload_position.new_line = position.new_line end
	if position.old_line ~= nil then payload_position.old_line = position.old_line end

	local payload_json = json.encode({ body = body, position = payload_position })

	-- Resolve project id ourselves so we can build the API path explicitly
	-- (the request goes through sys.cli.json with custom flags, not request_json).
	local project_id, id_err = client.resolve_project_id(repo)
	if id_err then return nil, id_err end

	-- Materialize the JSON body to a host-visible file. glab's `--input <file>`
	-- is the only form that preserves the nested `position` object; -F/-f flatten
	-- it and the comment is attached as a plain DiscussionNote instead.
	local vfs_path = string.format("gitlab/discussion_%s_%s_%d.json", tostring(project_id), tostring(iid), os.time())
	local _, write_err = sys.vfs.write_text(vfs_path, payload_json)
	if write_err then return nil, write_err end

	local exposed, expose_err = sys.vfs.expose({ vfs_path })
	if expose_err then return nil, expose_err end
	if type(exposed) ~= "table" or type(exposed.files) ~= "table" or exposed.files[1] == nil then
		return nil, { code = "VFS_EXPOSE_FAILED", message = "vfs.expose did not return a host path", recoverable = false }
	end
	local host_path = exposed.files[1].host_path

	local api_path = "projects/" .. tostring(project_id) .. "/merge_requests/" .. tostring(iid) .. "/discussions"
	local args = {
		"api", api_path,
		"--method", "POST",
		"-H", "Content-Type: application/json",
		"--input", host_path,
	}

	local result, cli_err = sys.cli.json("glab", args, {})
	if cli_err then return nil, cli_err end

	-- Per the documented rule: verify the response is actually a DiffNote, not
	-- a DiscussionNote (which would mean the position did not attach).
	if type(result) ~= "table" or type(result.notes) ~= "table" or result.notes[1] == nil then
		return result, {
			code = "UNEXPECTED_DISCUSSION_RESPONSE",
			message = "discussion response missing notes array",
			context = { iid = iid },
			recoverable = false,
		}
	end
	local note_type = result.notes[1].type
	if note_type ~= "DiffNote" then
		return result, {
			code = "POSITION_NOT_ATTACHED",
			message = "expected note type 'DiffNote' but got '" .. tostring(note_type) .. "' — position did not attach to the diff",
			context = { iid = iid, note_type = note_type, discussion_id = result.id },
			recoverable = false,
		}
	end

	return result, nil
end
