-- luacheck: globals compass compass_test

compass_test = compass_test or {}

local function status_entry(selected_env, target_env, extra)
	local entry = {
		configured = selected_env == target_env,
		used = selected_env == target_env,
	}

	for key, value in pairs(extra or {}) do
		entry[key] = value
	end

	return entry
end

function compass_test.reset_state()
	compass._auth = nil
	compass._cloud_id = nil
end

function compass_test.set_config(opts)
	opts = opts or {}

	local base_url = opts.base_url
	local base_url_env = opts.base_url_env
	local email_env = opts.email_env
	local token_env = opts.token_env

	compass._config = {
		base_url = base_url,
		base_url_env = base_url_env,
		email_env = email_env,
		token_env = token_env,
		graphql_path = opts.graphql_path or "/gateway/api/graphql",
		var_statuses = {
			COMPASS_BASE_URL = status_entry(base_url_env, "COMPASS_BASE_URL", { required = true, fallback = false }),
			JIRA_BASE_URL = status_entry(base_url_env, "JIRA_BASE_URL", { required = false, fallback = true }),
			COMPASS_EMAIL = status_entry(email_env, "COMPASS_EMAIL", { fallback = false }),
			JIRA_EMAIL = status_entry(email_env, "JIRA_EMAIL", { fallback = true }),
			COMPASS_API_TOKEN = status_entry(token_env, "COMPASS_API_TOKEN", { fallback = false, secret = true }),
			JIRA_API_TOKEN = status_entry(token_env, "JIRA_API_TOKEN", { fallback = true, secret = true }),
		},
	}

	compass_test.reset_state()

	return compass._config
end
