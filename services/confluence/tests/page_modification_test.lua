-- Tests for Confluence page modification: update and find_and_replace.
-- Mocks confluence._client._request_impl with a sequence-aware fake that responds to
-- GET / PUT / DELETE on /api/v2/pages/{id}.

local original_request_impl = confluence._client._request_impl

local _, mode_err = _raw.test.set_mode("mutating")
test.assert_nil(mode_err, "_raw.test.set_mode should enable mutating mode for confluence page modification tests")

confluence._config = {
	base_url = "https://test.atlassian.net/wiki",
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}
confluence._auth = { kind = "basic" }

-- Build a stateful mock for one test scenario. The mock tracks the page's
-- in-memory state so that GET reflects mutations made by the most recent PUT,
-- which is what `update`'s refresh+sanity check expects.
--
-- opts:
--   page_id           : id used in the path (default "123")
--   initial_version   : starting version number returned by GET (default 7)
--   initial_body      : storage body string returned by GET (default "<p>old</p>")
--   initial_title     : title returned by GET (default "Old Title")
--   stale_after_put   : if true, GET after PUT returns the OLD version
--                       (used to test UPDATE_NO_OP sanity check)
--   refresh_fails     : if true, GET after PUT returns an error
--   page_not_found    : if true, every GET returns 404 error
--   missing_storage   : if true, GET returns page with no body.storage
local function make_mock(opts)
	opts = opts or {}
	local page_id = opts.page_id or "123"
	local path = "/api/v2/pages/" .. page_id
	local current_version = opts.initial_version or 7
	local title = opts.initial_title or "Old Title"
	local status_value = opts.initial_status or "current"
	local body_value = opts.initial_body or "<p>old</p>"

	local calls = {}

	confluence._client._request_impl = function(method, _base_url, req_path, req)
		calls[#calls + 1] = {
			method = method,
			path = req_path,
			body = req and req.body,
			query = req and req.query,
		}

		if req_path ~= path then
			return nil, {
				code = "HTTP",
				message = "unexpected path: " .. tostring(req_path),
				recoverable = false,
			}
		end

		if method == "GET" then
			if opts.page_not_found then
				return nil, {
					code = "HTTP",
					message = "HTTP 404 Not Found",
					context = { status = 404 },
					recoverable = true,
				}
			end
			-- Detect post-PUT GET to simulate refresh failures / staleness.
			local after_put = false
			for i = #calls - 1, 1, -1 do
				if calls[i].method == "PUT" then
					after_put = true
					break
				end
			end
			if after_put and opts.refresh_fails then
				return nil, {
					code = "HTTP",
					message = "HTTP 500 (refresh)",
					context = { status = 500 },
					recoverable = true,
				}
			end
			local body
			if not opts.missing_storage then
				body = { storage = { value = body_value, representation = "storage" } }
			end
			return {
				id = page_id,
				status = status_value,
				title = title,
				body = body,
				version = { number = current_version },
			}, nil
		end

		if method == "PUT" then
			-- Apply the PUT to in-memory state so subsequent GETs reflect it.
			if req and req.body and req.body.body and type(req.body.body.value) == "string" then
				body_value = req.body.body.value
			end
			if req and req.body and req.body.title then
				title = req.body.title
			end
			if not opts.stale_after_put then
				if req and req.body and type(req.body.version) == "table" and type(req.body.version.number) == "number" then
					current_version = req.body.version.number
				else
					current_version = current_version + 1
				end
			end
			return { id = page_id, version = { number = current_version } }, nil
		end

		return nil, {
			code = "HTTP",
			message = "unexpected method: " .. tostring(method),
			recoverable = false,
		}
	end

	return calls
end

local function last_put(calls)
	for i = #calls, 1, -1 do
		if calls[i].method == "PUT" then
			return calls[i]
		end
	end
	return nil
end

local function count_method(calls, method)
	local n = 0
	for _, c in ipairs(calls) do
		if c.method == method then
			n = n + 1
		end
	end
	return n
end

-- ============================================================================
test.describe("Confluence Page Update - Content Body Forms")
-- ============================================================================

-- (1) data.content
local calls1 = make_mock()
local _, err1 = confluence.page.update("123", { content = "newC", version = { number = 8 } })
test.assert_nil(err1, "update with data.content should succeed")
local put1 = last_put(calls1)
test.assert_not_nil(put1, "PUT call should have happened")
test.assert_eq(put1.body.body.value, "newC", "PUT body.value should be data.content")
test.assert_eq(put1.body.body.representation, "storage", "default representation should be storage")

-- (2) data.body as string
local calls2 = make_mock()
local _, err2 = confluence.page.update("123", { body = "newC", version = { number = 8 } })
test.assert_nil(err2, "update with data.body=string should succeed")
test.assert_eq(last_put(calls2).body.body.value, "newC", "PUT body.value should be data.body string")

-- (3) data.body.value
local calls3 = make_mock()
local _, err3 = confluence.page.update("123", { body = { value = "newC" }, version = { number = 8 } })
test.assert_nil(err3, "update with data.body.value should succeed")
test.assert_eq(last_put(calls3).body.body.value, "newC", "PUT body.value should be data.body.value")

-- (4) data.body.storage.value
local calls4 = make_mock()
local _, err4 = confluence.page.update("123", {
	body = { storage = { value = "newC" } },
	version = { number = 8 },
})
test.assert_nil(err4, "update with data.body.storage.value should succeed")
test.assert_eq(last_put(calls4).body.body.value, "newC", "PUT body.value should match nested form")
test.assert_eq(last_put(calls4).body.body.representation, "storage", "representation should be storage")

-- (5) data.body.atlas_doc_format.value
local calls5 = make_mock()
local _, err5 = confluence.page.update("123", {
	body = { atlas_doc_format = { value = "ADF" } },
	version = { number = 8 },
})
test.assert_nil(err5, "update with data.body.atlas_doc_format.value should succeed")
test.assert_eq(last_put(calls5).body.body.value, "ADF", "PUT body.value should match ADF")
test.assert_eq(last_put(calls5).body.body.representation, "atlas_doc_format", "representation should be atlas_doc_format")

-- ============================================================================
test.describe("Confluence Page Update - Version Handling")
-- ============================================================================

-- (6) version omitted -> auto-fetch + increment
local calls6 = make_mock({ initial_version = 42 })
local _, err6 = confluence.page.update("123", { content = "x" })
test.assert_nil(err6, "update with no version should auto-fetch")
test.assert(count_method(calls6, "GET") >= 1, "should have called GET to fetch current version")
test.assert_eq(last_put(calls6).body.version.number, 43, "auto-incremented version should be current+1")

-- (7) version as plain number
local calls7 = make_mock()
local _, err7 = confluence.page.update("123", { content = "x", version = 99 })
test.assert_nil(err7, "update with numeric version should succeed")
test.assert_eq(last_put(calls7).body.version.number, 99, "numeric version should be wrapped to {number=N}")

-- (8) version as {number=N}
local calls8 = make_mock()
local _, err8 = confluence.page.update("123", { content = "x", version = { number = 10 } })
test.assert_nil(err8, "update with table version should succeed")
test.assert_eq(last_put(calls8).body.version.number, 10, "table version should pass through")

-- ============================================================================
test.describe("Confluence Page Update - Validation")
-- ============================================================================

-- (9) empty data table -> VALIDATION_FAILED
make_mock()
local _, err9 = confluence.page.update("123", {})
test.assert_not_nil(err9, "update with empty data should error")
test.assert_eq(err9.code, "VALIDATION_FAILED", "should be VALIDATION_FAILED")

-- (10) nil id -> MISSING_REQUIRED_FIELD
local _, err10 = confluence.page.update(nil, { content = "x" })
test.assert_not_nil(err10, "update with nil id should error")
test.assert_eq(err10.code, "MISSING_REQUIRED_FIELD", "should be MISSING_REQUIRED_FIELD")

-- (11) non-table data -> VALIDATION_FAILED
local _, err11 = confluence.page.update("123", "not-a-table")
test.assert_not_nil(err11, "update with string data should error")
test.assert_eq(err11.code, "VALIDATION_FAILED", "should be VALIDATION_FAILED")

-- ============================================================================
test.describe("Confluence Page Update - Refresh & Sanity")
-- ============================================================================

-- (12) PUT 200 but version did not advance -> UPDATE_NO_OP
make_mock({ stale_after_put = true })  -- refresh GET still returns the old version
local _, err12 = confluence.page.update("123", { content = "x", version = { number = 8 } })
test.assert_not_nil(err12, "stale refresh should error")
test.assert_eq(err12.code, "UPDATE_NO_OP", "should be UPDATE_NO_OP")

-- (13) refresh GET fails after successful PUT -> REFRESH_FAILED
make_mock({ refresh_fails = true })
local _, err13 = confluence.page.update("123", { content = "x", version = { number = 8 } })
test.assert_not_nil(err13, "refresh failure should error")
test.assert_eq(err13.code, "REFRESH_FAILED", "should be REFRESH_FAILED")
test.assert_not_nil(err13.context.original_error, "should preserve original_error")

-- ============================================================================
test.describe("Confluence Page Update - Explicit version + title")
-- ============================================================================

-- (14) Old-style call: content + version + title
local calls14 = make_mock()
local r14, err14 = confluence.page.update("123", {
	content = "<p>updated</p>",
	version = { number = 8 },
	title = "Updated Title",
})
test.assert_nil(err14, "explicit version+title update should succeed")
test.assert_not_nil(r14, "should return refreshed page")
test.assert_eq(last_put(calls14).body.body.value, "<p>updated</p>", "explicit content path should work")
test.assert_eq(last_put(calls14).body.title, "Updated Title", "explicit title should pass through")
test.assert_eq(last_put(calls14).body.version.number, 8, "explicit version should pass through")

-- ============================================================================
test.describe("Confluence Page Find and Replace")
-- ============================================================================

-- (19) plain mode, match
local calls19 = make_mock({ initial_body = "Hello world, hello world" })
local r19, err19 = confluence.page.find_and_replace("123", "hello", "HI")
test.assert_nil(err19, "find_and_replace should succeed when matched")
test.assert_eq(r19.replacements, 1, "should replace 1 match (case-sensitive)")
test.assert_eq(last_put(calls19).body.body.value, "Hello world, HI world", "PUT should contain replaced body")
test.assert_eq(last_put(calls19).body.version.number, 8, "find_and_replace should reuse fetched version and increment it")
test.assert_eq(last_put(calls19).body.title, "Old Title", "find_and_replace should reuse fetched title")
test.assert_eq(count_method(calls19, "GET"), 2, "find_and_replace should only do fetch+refresh GETs when it updates")

-- (20) plain mode with %, special chars in search and replacement should not crash
local calls20 = make_mock({ initial_body = "Score: 50% (good)" })
local r20, err20 = confluence.page.find_and_replace("123", "50%", "100%")
test.assert_nil(err20, "find_and_replace with % should not crash")
test.assert_eq(r20.replacements, 1, "should replace literal 50% with 100%")
test.assert_eq(last_put(calls20).body.body.value, "Score: 100% (good)", "PUT should contain literal replacement")

-- (21) pattern mode (opts.plain=false)
local calls21 = make_mock({ initial_body = "abc123def456" })
local r21, err21 = confluence.page.find_and_replace("123", "%d+", "N", { plain = false })
test.assert_nil(err21, "pattern mode should succeed")
test.assert_eq(r21.replacements, 2, "%d+ should match twice")
test.assert_eq(last_put(calls21).body.body.value, "abcNdefN", "pattern replace should work")

-- (22) opts.max limits substitutions
local calls22 = make_mock({ initial_body = "x x x x" })
local r22, err22 = confluence.page.find_and_replace("123", "x", "y", { max = 2 })
test.assert_nil(err22, "max-limited replace should succeed")
test.assert_eq(r22.replacements, 2, "should perform exactly 2 replacements")
test.assert_eq(last_put(calls22).body.body.value, "y y x x", "max=2 should leave remaining xs untouched")

-- (23) explicit version+title should preserve fetched status when caller omits it
local calls23 = make_mock({ initial_status = "draft" })
local _, err23 = confluence.page.update("123", {
	content = "<p>updated</p>",
	version = { number = 8 },
	title = "Updated Title",
})
test.assert_nil(err23, "explicit version+title update should preserve current status")
test.assert_eq(last_put(calls23).body.status, "draft", "status should be preserved from fetched page")

-- (24) refresh response missing version should error explicitly
make_mock({ stale_after_put = true })
local original_get = confluence.page.get
confluence.page.get = function(id, opts)
	local page, err = original_get(id, opts)
	if err or type(page) ~= "table" then
		return page, err
	end
	if page.version then
		page.version = nil
		return page, nil
	end
	return page, nil
end
local _, err24 = confluence.page.update("123", {
	content = "x",
	version = { number = 8 },
	title = "Updated Title",
	status = "current",
})
confluence.page.get = original_get
test.assert_not_nil(err24, "missing refresh version should error")
test.assert_eq(err24.code, "REFRESH_INVALID", "should be REFRESH_INVALID")

-- (25) no match, default -> NO_MATCH error, no PUT
local calls25 = make_mock({ initial_body = "<p>old</p>" })
local r25, err25 = confluence.page.find_and_replace("123", "missing", "found")
test.assert_nil(r25, "no-match should not return result")
test.assert_not_nil(err25, "no-match should error")
test.assert_eq(err25.code, "NO_MATCH", "should be NO_MATCH")
test.assert_eq(count_method(calls25, "PUT"), 0, "should not have issued a PUT")
test.assert_eq(count_method(calls25, "GET"), 1, "no-match should only fetch once")

-- (26) no match, allow_empty -> {page=current, replacements=0}, no PUT
local calls26 = make_mock({ initial_body = "<p>old</p>" })
local r26, err26 = confluence.page.find_and_replace("123", "missing", "found", { allow_empty = true })
test.assert_nil(err26, "allow_empty should not error on 0 matches")
test.assert_not_nil(r26, "allow_empty should return result")
test.assert_eq(r26.replacements, 0, "replacements should be 0")
test.assert_not_nil(r26.page, "result should include current page")
test.assert_eq(count_method(calls26, "PUT"), 0, "allow_empty should skip PUT")
test.assert_eq(count_method(calls26, "GET"), 1, "allow_empty should only fetch once")

-- ============================================================================
-- Cleanup
-- ============================================================================

confluence._client._request_impl = original_request_impl

test.summary()
