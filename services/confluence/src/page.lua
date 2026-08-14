-- Confluence page operations

local request = confluence._client.request
local list_request = confluence._client.list
local missing_required_field_err = confluence._client.missing_required_field_err

local raw_blob_from_http = sys.blob.from_http
local raw_vfs_write_blob = sys.vfs.write_blob
local raw_vfs_expose = sys.vfs.expose
local raw_url_path_escape = sys.url.path_escape

local function validation_err(message, context)
	return {
		code = "VALIDATION_FAILED",
		message = message,
		context = context or {},
		recoverable = false,
		suggestion = "Check the parameter values and retry",
	}
end

local function missing_body_err(page_id, body_format)
	return {
		code = "RESOURCE_NOT_FOUND",
		message = "Confluence page body is missing or not in the requested format",
		context = { page_id = page_id, body_format = body_format },
		recoverable = true,
		suggestion = "Verify the page ID and body format are correct",
	}
end

local function normalize_body_format(body_format)
	if body_format == nil or body_format == "" then
		return "storage"
	end
	return body_format
end

local known_representations = { "storage", "atlas_doc_format", "wiki", "editor", "view", "export_view" }

-- Extract content string from a flexible `data` table.
-- Accepted shapes (in priority order):
--   data.content                              (string)
--   data.body                                 (string)
--   data.body.value                           (string)
--   data.body.<representation>.value          (string)
-- Returns: (content_string|nil, representation|nil)
local function extract_content_from_data(data)
	if type(data.content) == "string" then
		return data.content, data.representation or "storage"
	end
	if type(data.body) == "string" then
		return data.body, data.representation or "storage"
	end
	if type(data.body) == "table" then
		if type(data.body.value) == "string" then
			return data.body.value, data.body.representation or data.representation or "storage"
		end
		for _, rep in ipairs(known_representations) do
			local sub = data.body[rep]
			if type(sub) == "table" and type(sub.value) == "string" then
				return sub.value, rep
			end
		end
	end
	return nil, nil
end

-- Normalize a version argument into Confluence v2 shape `{number = N}`.
-- Accepts: {number = N} | N (number) | nil. Returns nil for nil/invalid.
local function normalize_version(v)
	if type(v) == "table" and type(v.number) == "number" then
		return { number = v.number }
	end
	if type(v) == "number" then
		return { number = v }
	end
	return nil
end

local function sanitize_path_component(value)
	local sanitized = tostring(value or "image")
	sanitized = sanitized:gsub("[^A-Za-z0-9._-]", "-")
	sanitized = sanitized:gsub("-+", "-")
	sanitized = sanitized:gsub("^[-.]+", "")
	sanitized = sanitized:gsub("[-.]+$", "")
	if sanitized == "" then
		return "image"
	end
	return sanitized
end

local function next_unique_filename(base_name, used_names)
	if not used_names[base_name] then
		used_names[base_name] = 1
		return base_name
	end

	local stem, ext = base_name:match("^(.*)(%.[^.]+)$")
	if not stem then
		stem = base_name
		ext = ""
	end

	local suffix = used_names[base_name] + 1
	while true do
		local candidate = string.format("%s-%d%s", stem, suffix, ext)
		if not used_names[candidate] then
			used_names[base_name] = suffix
			used_names[candidate] = 1
			return candidate
		end
		suffix = suffix + 1
	end
end

local function guess_image_name_from_url(url)
	if type(url) ~= "string" or url == "" then
		return "image"
	end

	local clean = url:match("^[^?#]+") or url
	return clean:match("([^/]+)$") or "image"
end

local function append_unique_image_ref(refs, seen, ref)
	local key = tostring(ref.kind or "") .. ":" .. tostring(ref.source or ref.name or "")
	if seen[key] then
		return
	end

	seen[key] = true
	refs[#refs + 1] = ref
end

local function extract_storage_image_refs(body, refs, seen)
	for block in body:gmatch("<ac:image.-</ac:image>") do
		local filename = block:match('ri:attachment[^>]-ri:filename="([^"]+)"')
			or block:match("ri:attachment[^>]-ri:filename='([^']+)'")
		if filename then
			append_unique_image_ref(refs, seen, {
				kind = "attachment",
				name = filename,
				source = filename,
			})
		else
			local url = block:match('ri:url[^>]-ri:value="([^"]+)"')
				or block:match("ri:url[^>]-ri:value='([^']+)'")
			if url then
				append_unique_image_ref(refs, seen, {
					kind = "url",
					name = guess_image_name_from_url(url),
					source = url,
				})
			end
		end
	end
end

local function extract_html_image_refs(body, refs, seen)
	for _, src in body:gmatch("<img[^>]-src=(['\"])(.-)%1") do
		append_unique_image_ref(refs, seen, {
			kind = "url",
			name = guess_image_name_from_url(src),
			source = src,
		})
	end
end

local function collect_image_refs(body, body_format)
	local refs = {}
	local seen = {}
	if body_format == "storage" then
		extract_storage_image_refs(body, refs, seen)
	end
	extract_html_image_refs(body, refs, seen)
	return refs
end

local function resolve_same_tenant_path(url, base_url)
	if type(url) ~= "string" or url == "" then
		return nil
	end

	if url:match("^data:") then
		return nil
	end

	local root_url = base_url:gsub("/wiki$", "")
	if url:match("^https?://") then
		if url:sub(1, #base_url) == base_url then
			return url:sub(#base_url + 1)
		end
		if url:sub(1, #root_url) == root_url then
			local suffix = url:sub(#root_url + 1)
			if suffix:match("^/wiki/") then
				return suffix:gsub("^/wiki", "", 1)
			end
		end
		return nil
	end

	if url:match("^/wiki/") then
		return url:gsub("^/wiki", "", 1)
	end
	if url:match("^/") then
		return url
	end

	return "/" .. url
end

local function resolve_image_download_path(page_id, ref, base_url)
	if ref.kind == "attachment" and ref.name then
		return "/download/attachments/" .. tostring(page_id) .. "/" .. raw_url_path_escape(ref.name), ref.name
	end

	local path = resolve_same_tenant_path(ref.source, base_url)
	if not path then
		return nil, ref.name or guess_image_name_from_url(ref.source)
	end

	return path, ref.name or guess_image_name_from_url(ref.source)
end

local function build_page_image_hint(page_id, body, body_format)
	local refs = collect_image_refs(body, body_format)
	if #refs == 0 then
		return nil, nil
	end

	local base_url, base_url_err = confluence._client.get_base_url()
	if base_url_err then
		return nil, base_url_err
	end

	local auth, auth_err = confluence._client.get_auth()
	if auth_err then
		return nil, auth_err
	end

	local used_names = {}
	local images = {}
	local vfs_paths = {}
	for index, ref in ipairs(refs) do
		local download_path, image_name = resolve_image_download_path(page_id, ref, base_url)
		if download_path then
			local blob, blob_err = confluence.page._blob_from_http_impl("GET", base_url, download_path, {
				auth = auth,
			})
			if blob_err then
				return nil, blob_err
			end

			local safe_name = next_unique_filename(sanitize_path_component(image_name or ("image-" .. tostring(index))), used_names)
			local vfs_path = "confluence/pages/" .. tostring(page_id) .. "/images/" .. safe_name
			local info, write_err = confluence.page._vfs_write_blob_impl(vfs_path, blob, { overwrite = true })
			if write_err then
				return nil, write_err
			end

			images[#images + 1] = {
				name = image_name or safe_name,
				vfs_path = vfs_path,
				size = info and info.size or nil,
			}
			vfs_paths[#vfs_paths + 1] = vfs_path
		end
	end

	if #images == 0 then
		return nil, nil
	end

	local exposed, expose_err = confluence.page._vfs_expose_impl(vfs_paths)
	if expose_err then
		return nil, expose_err
	end

	local exposed_by_vfs_path = {}
	if exposed and type(exposed.files) == "table" then
		for _, file in ipairs(exposed.files) do
			if type(file) == "table" and file.original_vfs_path and file.host_path then
				exposed_by_vfs_path[file.original_vfs_path] = file
			end
		end
	end

	local lines = {
		string.format("This page contains %d image file(s). They were saved in the session VFS and exposed as temporary host files. You can read these files using the paths below and reason about their visual content if needed.", #images),
	}
	for _, image in ipairs(images) do
		local exposed_file = exposed_by_vfs_path[image.vfs_path]
		if exposed_file and exposed_file.host_path then
			lines[#lines + 1] = string.format("- %s -> %s", image.name, exposed_file.host_path)
		else
			lines[#lines + 1] = string.format("- %s", image.name)
		end
	end

	return table.concat(lines, "\n"), nil
end

local function attach_page_hint(page, body_format)
	if type(page) ~= "table" then
		return page, nil
	end

	local body = page.body
	if type(body) ~= "table" then
		return page, nil
	end

	local key = normalize_body_format(body_format)
	local rep = body[key]
	if type(rep) ~= "table" or type(rep.value) ~= "string" then
		return page, nil
	end

	local hint, err = build_page_image_hint(page.id, rep.value, key)
	if err == nil then
		page.hint = hint
	end

	return page, nil
end

local function extract_body_value(page, body_format)
	if type(page) ~= "table" then
		return nil
	end

	local body = page.body
	if type(body) ~= "table" then
		return nil
	end

	local key = normalize_body_format(body_format)
	local rep = body[key]
	if type(rep) ~= "table" then
		return nil
	end

	-- Confluence representations typically have { value = "...", representation = "..." }
	-- Some (e.g., atlas_doc_format) may have a non-string value.
	return rep.value
end

local function extract_page_id_from_url(url)
	if type(url) ~= "string" then
		return nil
	end

	-- Common forms:
	-- 1) https://<site>.atlassian.net/wiki/spaces/KEY/pages/123456/Title
	-- 2) https://<site>.atlassian.net/wiki/pages/viewpage.action?pageId=123456
	-- 3) ...?pageId=123456
	-- Match case-insensitively: pageId, pageid, PageId, PAGEID, etc.
	local from_query = url:match("[?&][Pp][Aa][Gg][Ee][Ii][Dd]=(%d+)")
	if from_query then
		return tonumber(from_query)
	end

	local from_path = url:match("/pages/(%d+)")
	if from_path then
		return tonumber(from_path)
	end

	return nil
end

-- Expose for tests/debug (not part of public service API)
confluence.page._extract_page_id_from_url = extract_page_id_from_url
confluence.page._blob_from_http_impl = raw_blob_from_http
confluence.page._vfs_write_blob_impl = raw_vfs_write_blob
confluence.page._vfs_expose_impl = raw_vfs_expose

-- V2.0 API: Get full page object by id.
-- Returns: (Page, err)
-- opts: { body_format = "storage"|"view"|"export_view"|"atlas_doc_format", get_draft?:boolean, version?:number }
function confluence.page.get(id, opts)
	if id == nil or tostring(id) == "" then
		return nil, missing_required_field_err("id", "page")
	end

	opts = opts or {}
	local body_format = normalize_body_format(opts.body_format or opts.format)

	local query = {
		["body-format"] = body_format,
	}
	if opts.get_draft ~= nil then
		query["get-draft"] = opts.get_draft
	end
	if opts.version ~= nil then
		query["version"] = opts.version
	end

	local path = "/api/v2/pages/" .. tostring(id)
	local page, err = request("GET", path, { query = query })
	if err then
		return nil, err
	end

	return attach_page_hint(page, body_format)
end

-- V2.0 API: Get page content in specified format.
-- Returns: (string, err)
-- opts: { format = "storage"|"view"|"export_view" }
function confluence.page.content(id, opts)
	if id == nil or tostring(id) == "" then
		return nil, missing_required_field_err("id", "page")
	end

	opts = opts or {}
	local format = opts.format or "storage"

	local page, err = confluence.page.get(id, { body_format = format })
	if err then
		return nil, err
	end

	local value = extract_body_value(page, format)
	if value == nil then
		return nil, missing_body_err(id, format)
	end

	if type(value) ~= "string" then
		return nil, {
			code = "INVALID_FORMAT",
			message = "Requested Confluence body format did not return a string",
			context = { page_id = id, body_format = format, value_type = type(value) },
			recoverable = true,
			suggestion = "Use a different format (storage, view, or export_view)",
		}
	end

	if type(page.hint) == "string" and page.hint ~= "" then
		return value .. "\n\n" .. page.hint, nil
	end

	return value, nil
end

-- V2.0 API: Find page by URL.
-- Returns: (Page, err)
function confluence.page.find(url)
	if url == nil or url == "" then
		return nil, missing_required_field_err("url", "page")
	end

	local page_id = extract_page_id_from_url(url)
	if not page_id then
		return nil, {
			code = "VALIDATION_FAILED",
			message = "Could not extract page id from URL",
			context = { page_url = url },
			recoverable = true,
			suggestion = "Provide a full Confluence page URL containing '/pages/<id>/' or '?pageId=<id>'",
		}
	end

	return confluence.page.get(page_id)
end

-- V2.0 API: List pages in a space.
-- Returns: Iterator<Page>
-- opts: { limit, title, status = "current"|"archived"|"draft"|"trashed" }
function confluence.page.list(space_key, opts)
	if space_key == nil or space_key == "" then
		error(missing_required_field_err("space_key", "space"))
	end

	opts = opts or {}

	local query = {
		["space-id"] = space_key,
	}
	if opts.title then
		query.title = opts.title
	end
	if opts.status then
		query.status = opts.status
	end

	local iterator, err = list_request("/api/v2/pages", {
		query = query,
		pagination = {
			kind = "cursor",
			items_path = "results",
			next_token_path = "_links.next",
			limit_param = "limit",
		},
		limit = opts.limit,
		per_page = opts.per_page or 25,
	})
	if err then
		error(err)
	end

	return iterator
end

-- V2.0 API: Create a new page.
-- Returns: (Page, err)
-- data: { space_key, title, content, parent_id?, status? }
function confluence.page.create(space_key, data)
	if space_key == nil or space_key == "" then
		return nil, missing_required_field_err("space_key", "page")
	end

	if type(data) ~= "table" then
		return nil, validation_err("data must be a table", { data_type = type(data) })
	end

	if not data.title or data.title == "" then
		return nil, missing_required_field_err("title", "page")
	end

	if not data.content then
		return nil, missing_required_field_err("content", "page")
	end

	local body = {
		spaceId = space_key,
		status = data.status or "current",
		title = data.title,
		body = {
			representation = data.representation or "storage",
			value = data.content,
		},
	}

	if data.parent_id then
		body.parentId = tostring(data.parent_id)
	end

	local result, err = request("POST", "/api/v2/pages", { body = body })
	if err then
		return nil, err
	end

	return result, nil
end

-- Internal: fetch current storage body value for content helpers.
-- Returns: (body_string|nil, page|nil, err)
local function fetch_current_storage_value(id)
	local page, err = confluence.page.get(id, { body_format = "storage" })
	if err then
		return nil, nil, err
	end
	local storage = page.body and page.body.storage
	if type(storage) ~= "table" or type(storage.value) ~= "string" then
		return nil, nil, missing_body_err(id, "storage")
	end
	return storage.value, page, nil
end

local function validate_page_for_update(page)
	if type(page) ~= "table" then
		return validation_err("page must be a table", { page_type = type(page) })
	end
	if type(page.version) ~= "table" or type(page.version.number) ~= "number" then
		return {
			code = "API_ERROR",
			message = "page.version.number missing in GET response",
			context = { page_id = page.id },
			recoverable = false,
		}
	end

	return nil
end

local function build_storage_update_data(page, content)
	local err = validate_page_for_update(page)
	if err then
		return nil, err
	end
	if type(page.title) ~= "string" or page.title == "" then
		return nil, {
			code = "API_ERROR",
			message = "page.title missing in GET response",
			context = { page_id = page.id },
			recoverable = false,
		}
	end

	return {
		content = content,
		representation = "storage",
		version = { number = page.version.number + 1 },
		title = page.title,
		status = page.status,
	}, nil
end

-- V2.0 API: Update an existing page.
-- Returns: (Page, err) where Page is the refreshed state after PUT+GET.
--
-- Accepts content in multiple forms (priority order):
--   data.content                              (string)
--   data.body                                 (string)
--   data.body.value                           (string)
--   data.body.<representation>.value          (string, representation derived)
--
-- Version handling:
--   data.version omitted -> GET current page, send {number = current+1}
--   data.version = N (number) -> wraps as {number = N}
--   data.version = {number = N} -> used as is
--
-- After PUT, refreshes via GET and verifies version advanced (sanity check
-- against silent no-op when body field is dropped server-side).
function confluence.page.update(id, data)
	if id == nil or tostring(id) == "" then
		return nil, missing_required_field_err("id", "page")
	end

	if type(data) ~= "table" then
		return nil, validation_err("data must be a table", { data_type = type(data) })
	end

	local content, rep = extract_content_from_data(data)
	local title = data.title
	local status = data.status
	local parent = data.parent_id

	if content == nil and title == nil and status == nil and parent == nil then
		return nil, validation_err(
			"update requires at least one of: content, title, status, parent_id",
			{ page_id = id }
		)
	end

	-- Confluence v2 PUT requires title even if unchanged, and version must be
	-- current+1 if the caller didn't supply one. Fetch the current page once
	-- when either version, title, or status needs to be preserved and reuse it.
	local version = normalize_version(data.version)
	local prev_version_number
	if version == nil or title == nil or status == nil then
		local cur, gerr = confluence.page.get(id, { body_format = "storage" })
		if gerr then
			return nil, gerr
		end
		local validation = validate_page_for_update(cur)
		if validation then
			return nil, validation
		end
		if version == nil then
			prev_version_number = cur.version.number
			version = { number = cur.version.number + 1 }
		end
		if title == nil then
			title = cur.title
		end
		if status == nil then
			status = cur.status
		end
	end
	if prev_version_number == nil then
		-- Caller supplied an explicit version, so use version.number-1 as the
		-- minimum previous version we expect to have advanced past. This treats
		-- any refreshed version >= the requested version as success.
		prev_version_number = version.number - 1
	end

	local body = {
		id = tostring(id),
		status = status or "current",
		title = title,
		version = version,
	}
	if content ~= nil then
		body.body = {
			representation = rep or "storage",
			value = content,
		}
	end
	if parent ~= nil then
		body.parentId = tostring(parent)
	end

	local _put_result, err = request("PUT", "/api/v2/pages/" .. tostring(id), { body = body })
	if err then
		return nil, err
	end

	-- Refresh pattern (SERVICE-DESIGN.mkd §5.3): re-fetch and return current state.
	local refreshed, refresh_err = confluence.page.get(id, { body_format = rep or "storage" })
	if refresh_err then
		return nil, {
			code = "REFRESH_FAILED",
			message = "page updated but refresh GET failed: " .. (refresh_err.message or ""),
			context = { page_id = id, original_error = refresh_err },
			recoverable = true,
			suggestion = "Call confluence.page.get(id) to fetch current state",
		}
	end

	-- Sanity check: version actually advanced. Without this, a silent no-op
	-- (e.g., body field dropped server-side, the original bug) goes unnoticed.
	if type(refreshed.version) ~= "table" or type(refreshed.version.number) ~= "number" then
		return nil, {
			code = "REFRESH_INVALID",
			message = "page updated but refresh GET response is missing version.number",
			context = { page_id = id, refreshed = refreshed },
			recoverable = false,
			suggestion = "Call confluence.page.get(id) to inspect the current page state",
		}
	end
	if refreshed.version.number <= prev_version_number then
		return nil, {
			code = "UPDATE_NO_OP",
			message = "PUT returned 200 but page version did not advance",
			context = {
				page_id = id,
				expected_version = version.number,
				actual_version = refreshed.version.number,
			},
			recoverable = false,
			suggestion = "Verify request body shape (this typically means body field was dropped server-side)",
		}
	end

	return refreshed, nil
end

-- Find-and-replace in page body (storage representation).
-- opts: {
--   plain?:boolean = true,    -- escape Lua magic chars in pattern AND replacement
--   max?:number,              -- limit number of substitutions
--   allow_empty?:boolean,     -- if true, 0 matches returns {page=current, replacements=0} without PUT
-- }
-- Returns: ({page=Page, replacements=N}, nil) or (nil, err) — NO_MATCH error if 0 matches and not allow_empty.
function confluence.page.find_and_replace(id, search, replacement, opts)
	opts = opts or {}
	if type(search) ~= "string" or search == "" then
		return nil, validation_err("search must be a non-empty string")
	end
	if type(replacement) ~= "string" then
		return nil, validation_err("replacement must be a string")
	end

	local cur_body, page, err = fetch_current_storage_value(id)
	if err then
		return nil, err
	end

	local pattern = search
	local repl = replacement
	if opts.plain ~= false then
		-- Escape Lua pattern magic chars in the search string.
		pattern = (search:gsub("([%%%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"))
		-- In replacement strings, '%' is the only special char (used for backrefs).
		repl = (replacement:gsub("%%", "%%%%"))
	end

	local new_body, n
	if opts.max then
		new_body, n = cur_body:gsub(pattern, repl, opts.max)
	else
		new_body, n = cur_body:gsub(pattern, repl)
	end

	if n == 0 then
		if not opts.allow_empty then
			return nil, {
				code = "NO_MATCH",
				message = "find_and_replace: pattern did not match",
				context = { page_id = id, search = search, plain = opts.plain ~= false },
				recoverable = true,
				suggestion = "Check the search string or pass opts.allow_empty=true",
			}
		end
		return { page = page, replacements = 0 }, nil
	end

	local update_data, data_err = build_storage_update_data(page, new_body)
	if data_err then
		return nil, data_err
	end

	local updated, uerr = confluence.page.update(id, update_data)
	if uerr then
		return nil, uerr
	end
	return { page = updated, replacements = n }, nil
end

confluence.page.__schema = {
	namespace = "confluence.page",
	service = "confluence",
	description = "Confluence Cloud page operations (REST API v2)",
	functions = {
		{
			name = "get",
			signature = "(id, opts?)",
			description = "Get full page object by id. Returns complete Page with metadata. If the requested body representation contains Confluence-hosted images, they are saved and exposed for agent inspection and a hint field is added with image names and host paths.",
			readonly = true,
			returns_contract = "core.result",
			params = {
				{ name = "id", type = "string|number", optional = false, description = "Page id" },
				{ name = "opts", type = "table", optional = true, description = "Options: body_format, get_draft, version" },
			},
			returns_typed = {
				{ name = "result", type = "Page" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
-- Get full page object
local page, err = confluence.page.get(123456)
if err then error(err.message) end
return page
			]],
		},
		{
			name = "content",
			signature = "(id, opts?)",
			description = "Get page content in specified format (storage, view, or export_view). If Confluence-hosted images are detected, they are saved and exposed for agent inspection and the page hint is appended to the end of the returned body text.",
			readonly = true,
			returns_contract = "core.result",
			params = {
				{ name = "id", type = "string|number", optional = false, description = "Page id" },
				{ name = "opts", type = "table", optional = true, description = "Options: format (storage|view|export_view)" },
			},
			returns_typed = {
				{ name = "result", type = "string" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
-- Get page content in storage format
local content, err = confluence.page.content(123456, {format = "storage"})
if err then error(err.message) end
return content
			]],
		},
		{
			name = "find",
			signature = "(url)",
			description = "Find page by URL. Extracts page ID from URL and returns full Page object.",
			readonly = true,
			returns_contract = "core.result",
			params = {
				{ name = "url", type = "string", optional = false, description = "Confluence page URL containing /pages/<id>/ or ?pageId=<id>" },
			},
			returns_typed = {
				{ name = "result", type = "Page" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
-- Find page by URL
local page, err = confluence.page.find("https://wiki.company.com/pages/123456")
if err then error(err.message) end
return page
			]],
		},
		{
			name = "list",
			signature = "(space_key, opts?)",
			description = "List pages in a space. Returns iterator for lazy pagination.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "Page",
			params = {
				{ name = "space_key", type = "string", optional = false, description = "Space key or ID" },
				{ name = "opts", type = "table", optional = true, description = "Options: limit, title, status" },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
-- List pages in a space
local pages = helpers.collect(
  confluence.page.list("SPACE"),
  {limit = 10}
)
return pages
			]],
		},
		{
			name = "create",
			signature = "(space_key, data)",
			description = "Create a new page in a space.",
			readonly = false,
			returns_contract = "core.result",
			params = {
				{ name = "space_key", type = "string", optional = false, description = "Space key or ID" },
				{ name = "data", type = "table", optional = false, description = "Page data: {title, content, parent_id?, status?, representation?}" },
			},
			returns_typed = {
				{ name = "result", type = "Page" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
-- Create new page
local page, err = confluence.page.create("SPACE", {
  title = "New Documentation Page",
  content = "<p>Page content in storage format</p>",
  parent_id = 123456
})
if err then error(err.message) end
return page
			]],
		},
		{
			name = "update",
			signature = "(id, data)",
			description = "Update an existing page. Accepts content as data.content, data.body (string), or data.body.<representation>.value. Version is optional: if omitted, current version is fetched and incremented; otherwise accepts {number=N} or a plain number. Title is reused from current page if omitted. Returns refreshed page after PUT+GET, with sanity check that version actually advanced (catches silent server-side no-ops).",
			readonly = false,
			returns_contract = "core.result",
			params = {
				{ name = "id", type = "string|number", optional = false, description = "Page id" },
				{ name = "data", type = "table", optional = false, description = "Update fields: {title?, content?|body?, version?, status?, parent_id?, representation?}" },
			},
			returns_typed = {
				{ name = "result", type = "Page" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
-- Minimal: change content; version auto-incremented, title kept.
local page, err = confluence.page.update(123456, {
  content = "<p>New body</p>"
})
if err then error(err.message) end
return page
			]],
		},
		{
			name = "find_and_replace",
			signature = "(id, search, replacement, opts?)",
			description = "String substitution in page body (storage representation). Default opts.plain=true treats search/replacement as literals (escapes Lua pattern magic). Returns {page, replacements}. Errors with NO_MATCH if no replacements unless opts.allow_empty=true.",
			readonly = false,
			returns_contract = "core.result",
			params = {
				{ name = "id", type = "string|number", optional = false, description = "Page id" },
				{ name = "search", type = "string", optional = false, description = "Search string (literal by default)" },
				{ name = "replacement", type = "string", optional = false, description = "Replacement string" },
				{ name = "opts", type = "table", optional = true, description = "{plain?:boolean=true, max?:number, allow_empty?:boolean}" },
			},
			returns_typed = {
				{ name = "result", type = "FindReplaceResult" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
local r, err = confluence.page.find_and_replace(123456, "TODO", "DONE")
if err then error(err.message) end
return r.replacements
			]],
		},
	},
	types = {
		Page = { shape = "{id:string, status:string, title:string, spaceId:string, body:table, version:table, _links:table, hint?:string}" },
		FindReplaceResult = { shape = "{page:Page, replacements:number}" },
	},
}
