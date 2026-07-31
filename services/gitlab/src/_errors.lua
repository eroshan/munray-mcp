-- preload/gitlab/_errors.lua
-- Internal GitLab error translation policy

local function lower_text(raw_err)
	local parts = {}

	if type(raw_err) == "string" then
		parts[#parts + 1] = raw_err
	elseif type(raw_err) == "table" then
		if type(raw_err.message) == "string" then
			parts[#parts + 1] = raw_err.message
		end

		local ctx = raw_err.context
		if type(ctx) == "table" then
			if type(ctx.stderr) == "string" then
				parts[#parts + 1] = ctx.stderr
			end
			if type(ctx.stdout) == "string" then
				parts[#parts + 1] = ctx.stdout
			end
		end
	end

	return table.concat(parts, "\n"):lower()
end

local ok, err = errutil.register_policy("gitlab", {
	classify = function(raw_err, _meta)
		local text = lower_text(raw_err)

		if text:find("404 project not found", 1, true) then
			return {
				code = "RESOURCE_NOT_FOUND",
				message = "GitLab project not found or not accessible",
				recoverable = false,
				hint = "Verify the repository path and GitLab permissions.",
			}
		end

		if text:find("http 403", 1, true) or text:find("forbidden", 1, true) then
			return {
				code = "ACCESS_DENIED",
				message = "Access to the GitLab resource was denied",
				recoverable = false,
				hint = "Verify GitLab permissions or authentication.",
			}
		end

		if text:find("http 401", 1, true) or text:find("unauthorized", 1, true) then
			return {
				code = "AUTH_FAILED",
				message = "GitLab authentication is required",
				recoverable = true,
				hint = "Authenticate GitLab CLI/API access and retry.",
			}
		end

		if text:find("http 429", 1, true) or text:find("rate limit", 1, true) then
			return {
				code = "RATE_LIMITED",
				message = "GitLab rate limit reached",
				recoverable = true,
				hint = "Retry after waiting briefly.",
			}
		end

		return nil
	end,

	fallback = function(raw_err, meta)
		local recoverable = false
		if type(raw_err) == "table" and type(raw_err.recoverable) == "boolean" then
			recoverable = raw_err.recoverable
		end

		if meta and meta.kind == "list" then
			return {
				code = "UPSTREAM_ERROR",
				message = "GitLab list request failed",
				recoverable = recoverable,
				hint = "Retry later or verify GitLab access if the problem persists.",
			}
		end

		return {
			code = "UPSTREAM_ERROR",
			message = "GitLab request failed",
			recoverable = recoverable,
			hint = "Retry later or verify GitLab access if the problem persists.",
		}
	end,

	public_context_allowlist = {
		repo = true,
		path = true,
		ref = true,
		iid = true,
		branch = true,
		group = true,
	},
})
if err then error(err, 0) end
if not ok then error("gitlab error policy registration failed", 0) end

gitlab._errors = errutil.for_service("gitlab")
