-- Example: confluence.page
-- Requires: JIRA_BASE_URL, JIRA_EMAIL, and JIRA_API_TOKEN

-- Check if Confluence is ready (configured and reachable)
local ready, ready_err = confluence.ready()
if not ready then
	print("ERROR: Confluence is not ready")
	print("Reason:", ready_err.message)
	return
end

-- Get full page object
local page, err = confluence.page.get(123456)
if err then error(err.message or tostring(err)) end
print("Got page:", page.title)

-- Get page content in storage format
local content, err2 = confluence.page.content(123456, {format = "storage"})
if err2 then error(err2.message or tostring(err2)) end
print("Content length:", #content)

-- Find page by URL
local found, err3 = confluence.page.find("https://wiki.company.com/pages/123456")
if err3 then error(err3.message or tostring(err3)) end
print("Found page:", found.title)

-- List pages in a space
local pages = helpers.collect(
	confluence.page.list("SPACE"),
	{limit = 5}
)
print("Pages found:", #pages)

-- Modification examples (require mutating mode)

-- Update content with auto-version (no need to fetch current version first)
local updated, err4 = confluence.page.update(123456, {
	content = "<p>Updated body</p>"
})
if err4 then error(err4.message) end
print("Updated to version:", updated.version.number)

-- Update accepts Confluence-style nested body too
local _, err5 = confluence.page.update(123456, {
	body = { storage = { value = "<p>Also works</p>" } },
})
if err5 then error(err5.message) end

-- Find-and-replace within page body (literal match by default)
local result, err6 = confluence.page.find_and_replace(123456, "TODO", "DONE")
if err6 then error(err6.message) end
print("Replacements:", result.replacements)
