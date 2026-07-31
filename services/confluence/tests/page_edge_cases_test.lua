-- Additional Confluence page tests for edge cases and URL extraction

test.describe("Confluence Page - URL Extraction Edge Cases")

-- Test malformed URLs
local result = confluence.page._extract_page_id_from_url("not-a-url")
test.assert_eq(result, nil, "should return nil for invalid URL")

result = confluence.page._extract_page_id_from_url("")
test.assert_eq(result, nil, "should return nil for empty string")

result = confluence.page._extract_page_id_from_url(nil)
test.assert_eq(result, nil, "should return nil for nil input")

-- Test URLs without page IDs
result = confluence.page._extract_page_id_from_url("https://example.com/wiki/spaces/KEY")
test.assert_eq(result, nil, "should return nil for URL without page ID")

-- Test Unicode in URLs
result = confluence.page._extract_page_id_from_url("https://example.atlassian.net/wiki/spaces/KEY/pages/123456/页面标题")
test.assert_eq(result, 123456, "should extract page ID from URL with Unicode characters")

-- Test very long URLs (>2000 chars)
local long_url = "https://example.atlassian.net/wiki/spaces/KEY/pages/999999/" .. string.rep("a", 2000)
result = confluence.page._extract_page_id_from_url(long_url)
test.assert_eq(result, 999999, "should extract page ID from very long URL")

-- Test URL with query parameters
result = confluence.page._extract_page_id_from_url("https://example.atlassian.net/wiki/pages/viewpage.action?pageId=555555&foo=bar")
test.assert_eq(result, 555555, "should extract page ID from URL with multiple query params")

-- Test URL with fragment
result = confluence.page._extract_page_id_from_url("https://example.atlassian.net/wiki/spaces/KEY/pages/777777/Title#section")
test.assert_eq(result, 777777, "should extract page ID from URL with fragment")

-- Test case sensitivity in pageId parameter
result = confluence.page._extract_page_id_from_url("https://example.atlassian.net/wiki?PageId=888888")
test.assert_eq(result, 888888, "should handle case variations in pageId parameter")

test.describe("Confluence Page - Body Format Normalization")

-- Test default body format
local opts = {}
local _, err = confluence.page.get(nil, opts)
test.assert_not_nil(err, "should return error for nil page_id")

-- Test empty body format defaults to storage
result, err = confluence.page.get("", { body_format = "" })
test.assert_not_nil(err, "should return error for empty page_id")

test.describe("Confluence Page - Error Handling")

-- Test get with nil page_id
result, err = confluence.page.get(nil)
test.assert_eq(result, nil, "should return nil result")
test.assert_not_nil(err, "should return error")
test.assert_eq(err.code, "MISSING_REQUIRED_FIELD", "should return MISSING_REQUIRED_FIELD error")
test.assert_not_nil(err.context, "error should have context")
test.assert_eq(err.context.field, "id", "context should include field id")

test.assert_eq(type(confluence.page.text), "nil", "page.text should not be exposed")
test.assert_eq(type(confluence.page.get_page), "nil", "page.get_page should not be exposed")
test.assert_eq(type(confluence.page.get_by_url), "nil", "page.get_by_url should not be exposed")

-- Test find with URL without page ID
result, err = confluence.page.find("https://example.atlassian.net/wiki/spaces/KEY/overview")
test.assert_eq(result, nil, "should return nil result")
test.assert_not_nil(err, "should return error")
test.assert_eq(err.code, "VALIDATION_FAILED", "should return VALIDATION_FAILED error")

test.describe("Confluence Page - Rate Limiting and HTTP Errors")

-- Save original implementation
local original_request = confluence._client._request_impl

-- Test 401 Unauthorized
confluence._client._request_impl = function(_method, _base_url, _path, _req)
	return nil, {
		code = "HTTP",
		message = "HTTP 401 Unauthorized",
		context = { status = 401 },
		recoverable = false
	}
end

confluence._config = {
	base_url = "https://test.atlassian.net/wiki",
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}
confluence._auth = { kind = "basic" }

result, err = confluence.page.get(123456)
test.assert_eq(result, nil, "should return nil on 401")
test.assert_not_nil(err, "should return error on 401")
test.assert_eq(err.code, "HTTP", "should return HTTP error")

-- Test 404 Not Found
confluence._client._request_impl = function(_method, _base_url, _path, _req)
	return nil, {
		code = "HTTP",
		message = "HTTP 404 Not Found",
		context = { status = 404 },
		recoverable = true
	}
end

result, err = confluence.page.get(999999)
test.assert_eq(result, nil, "should return nil on 404")
test.assert_not_nil(err, "should return error on 404")
test.assert_eq(err.code, "HTTP", "should return HTTP error")

-- Test 429 Rate Limit
confluence._client._request_impl = function(_method, _base_url, _path, _req)
	return nil, {
		code = "HTTP",
		message = "HTTP 429 Too Many Requests",
		context = { status = 429 },
		recoverable = true
	}
end

result, err = confluence.page.get(123456)
test.assert_eq(result, nil, "should return nil on rate limit")
test.assert_not_nil(err, "should return error on rate limit")
test.assert_eq(err.code, "HTTP", "should return HTTP error")
test.assert_eq(err.recoverable, true, "rate limit error should be recoverable")

-- Restore original
confluence._client._request_impl = original_request

test.describe("Confluence Page - Image Exposure Annotation")

local original_request_impl = confluence._client._request_impl
local original_blob_impl = confluence.page._blob_from_http_impl
local original_write_blob_impl = confluence.page._vfs_write_blob_impl
local original_expose_impl = confluence.page._vfs_expose_impl

local captured_image_paths = {}
local captured_vfs_writes = {}
confluence._client._request_impl = function(method, base_url, path, req)
	if method == "GET" and path == "/api/v2/pages/123456" then
		return {
			id = "123456",
			title = "Architecture",
			body = {
				storage = {
					value = '<p>Hello</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image><ac:image><ri:attachment ri:filename="logo team.png" /></ac:image>',
				},
			},
		}, nil
	end
	return nil, {
		code = "HTTP",
		message = "unexpected request",
		context = { method = method, base_url = base_url, path = path, req = req },
		recoverable = false,
	}
end

confluence.page._blob_from_http_impl = function(method, base_url, path, request_opts)
	captured_image_paths[#captured_image_paths + 1] = {
		method = method,
		base_url = base_url,
		path = path,
		auth = request_opts and request_opts.auth or nil,
	}
	return { kind = "blob", path = path }, nil
end

confluence.page._vfs_write_blob_impl = function(path, blob, write_opts)
	captured_vfs_writes[#captured_vfs_writes + 1] = {
		path = path,
		blob = blob,
		overwrite = write_opts and write_opts.overwrite or nil,
	}
	return { path = path, size = 12, is_dir = false }, nil
end

confluence.page._vfs_expose_impl = function(paths)
	return {
		files = {
			{
				original_vfs_path = paths[1],
				host_path = "/tmp/exposed/diagram.png",
				size = 12,
				mime = "image/png",
			},
			{
				original_vfs_path = paths[2],
				host_path = "/tmp/exposed/logo-team.png",
				size = 12,
				mime = "image/png",
			},
		},
	}, nil
end

confluence._config = {
	base_url = "https://example.atlassian.net/wiki",
	base_url_env = "JIRA_BASE_URL",
	auth_email_env = "JIRA_EMAIL",
	auth_token_env = "JIRA_API_TOKEN",
}
confluence._auth = { kind = "basic" }

local page_with_images, page_image_err = confluence.page.get(123456, { body_format = "storage" })
test.assert_eq(page_image_err, nil, "page.get with images should not return error")
test.assert_not_nil(page_with_images, "page.get with images should return page object")
test.assert_eq(page_with_images.body.storage.value, '<p>Hello</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image><ac:image><ri:attachment ri:filename="logo team.png" /></ac:image>', "page.get should preserve original body value")
test.assert_not_nil(page_with_images.hint, "page.get should add hint field when images are exposed")
test.assert(page_with_images.hint:match("diagram%.png %-%> /tmp/exposed/diagram%.png") ~= nil, "page.get hint should include first image path")
test.assert(page_with_images.hint:match("logo team%.png %-%> /tmp/exposed/logo%-team%.png") ~= nil, "page.get hint should include second image path")

captured_image_paths = {}
captured_vfs_writes = {}
local content_value, image_err = confluence.page.content(123456, { format = "storage" })
test.assert_eq(image_err, nil, "content with images should not return error")
test.assert_not_nil(content_value, "content with images should return content")
test.assert(content_value:match('^<p>Hello</p><ac:image><ri:attachment ri:filename="diagram%.png" /></ac:image><ac:image><ri:attachment ri:filename="logo team%.png" /></ac:image>') ~= nil, "content should start with original body")
test.assert(content_value:match("diagram%.png %-%> /tmp/exposed/diagram%.png") ~= nil, "content should append first image path hint")
test.assert(content_value:match("logo team%.png %-%> /tmp/exposed/logo%-team%.png") ~= nil, "content should append second image path hint")
test.assert_eq(#captured_image_paths, 2, "content should download two page images")
test.assert_eq(captured_image_paths[1].method, "GET", "image downloads should use GET")
test.assert_eq(captured_image_paths[1].path, "/download/attachments/123456/diagram.png", "first image should use attachment download path")
test.assert_eq(captured_image_paths[2].path, "/download/attachments/123456/logo%20team.png", "second image should escape spaces in attachment download path")
test.assert_eq(#captured_vfs_writes, 2, "content should write two blobs to VFS")
test.assert_eq(captured_vfs_writes[1].path, "confluence/pages/123456/images/diagram.png", "first image should use predictable VFS path")
test.assert_eq(captured_vfs_writes[2].path, "confluence/pages/123456/images/logo-team.png", "second image should sanitize VFS filename")

test.describe("Confluence Page - Image Exposure Best Effort")

confluence.page._blob_from_http_impl = function(_method, _base_url, path, _opts)
	if path == "/download/attachments/123456/diagram.png" then
		return nil, {
			code = "HTTP",
			message = "broken image",
			recoverable = true,
		}
	end
	return { kind = "blob", path = path }, nil
end

captured_vfs_writes = {}
local page_without_hint, page_without_hint_err = confluence.page.get(123456, { body_format = "storage" })
test.assert_eq(page_without_hint_err, nil, "page.get should still succeed when image hint generation fails")
test.assert_not_nil(page_without_hint, "page.get should still return the page when image hint generation fails")
test.assert_eq(page_without_hint.body.storage.value, '<p>Hello</p><ac:image><ri:attachment ri:filename="diagram.png" /></ac:image><ac:image><ri:attachment ri:filename="logo team.png" /></ac:image>', "page.get should preserve original body when image hint generation fails")
test.assert_eq(page_without_hint.hint, nil, "page.get should omit hint when image hint generation fails")
test.assert_eq(#captured_vfs_writes, 0, "page.get should stop writing images when the first image download fails")

confluence._client._request_impl = original_request_impl
confluence.page._blob_from_http_impl = original_blob_impl
confluence.page._vfs_write_blob_impl = original_write_blob_impl
confluence.page._vfs_expose_impl = original_expose_impl

test.summary()
