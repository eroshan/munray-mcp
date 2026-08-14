-- gcloud.monitoring.* implementation
-- Read Cloud Monitoring metrics via Monitoring REST API and alert resources via gcloud CLI.

local raw_cli_json = sys.cli.json
local raw_http_list = sys.http.list
local raw_secrets_command = sys.secrets.command
local raw_auth_bearer = sys.auth.bearer

local MONITORING_BASE_URL = "https://monitoring.googleapis.com"
local GCLOUD_TOKEN_TTL_SECONDS = 3600
local GCLOUD_TOKEN_TIMEOUT_SECONDS = 10

local monitoring_token, monitoring_token_err = raw_secrets_command({
	tool = "gcloud",
	args = {"auth", "print-access-token"},
	timeout = GCLOUD_TOKEN_TIMEOUT_SECONDS,
	ttl_s = GCLOUD_TOKEN_TTL_SECONDS,
})

local monitoring_auth, monitoring_auth_err = nil, nil
if monitoring_token_err == nil then
	monitoring_auth, monitoring_auth_err = raw_auth_bearer(monitoring_token)
end

local function get_monitoring_auth()
	if monitoring_token_err ~= nil then
		return nil, monitoring_token_err
	end
	if monitoring_auth_err ~= nil then
		return nil, monitoring_auth_err
	end
	return monitoring_auth, nil
end

local function validate_gcp_project_id(project)
	if not project or type(project) ~= "string" then
		return false, "project must be a string"
	end

	if #project < 6 or #project > 30 then
		return false, "project ID must be 6-30 characters"
	end

	if not project:match("^[a-z][a-z0-9%-]*[a-z0-9]$") then
		return false, "project ID contains invalid characters or format"
	end

	if project:match("%-%-") then
		return false, "project ID cannot contain consecutive hyphens"
	end

	return true, nil
end

local function err_required(name, value)
	return {
		code = "MISSING_REQUIRED_FIELD",
		message = name .. " parameter is required",
		recoverable = false,
		context = { [name] = value },
	}
end

local function err_invalid(name, reason, value)
	return {
		code = "INVALID_FIELD_VALUE",
		message = "Invalid " .. name .. ": " .. (reason or "validation failed"),
		recoverable = false,
		context = { [name] = value, reason = reason },
	}
end

local function validate_project(project)
	if not project or type(project) ~= "string" or project == "" then
		return nil, err_required("project", project)
	end

	local valid, reason = validate_gcp_project_id(project)
	if not valid then
		return nil, err_invalid("project", reason, project)
	end

	return project, nil
end

local function validate_opts_table(opts)
	if opts == nil then
		return {}, nil
	end
	if type(opts) ~= "table" then
		return nil, {
			code = "INVALID_OPTIONS",
			message = "opts must be a table",
			recoverable = false,
			context = { opts_type = type(opts) },
		}
	end
	return opts, nil
end

local function validate_rfc3339ish(name, value)
	if type(value) ~= "string" or value == "" then
		return false, name .. " must be a non-empty RFC3339 timestamp string"
	end
	if not value:find("T", 1, true) then
		return false, name .. " must contain 'T' separator"
	end
	if not (value:find("Z", 1, true) or value:find("+", 1, true) or value:sub(-6, -6) == "-") then
		return false, name .. " must include timezone information"
	end
	return true, nil
end

local function coerce_positive_number(name, value)
	if value == nil then
		return nil, nil
	end
	if type(value) ~= "number" then
		return nil, err_invalid(name, name .. " must be a number", value)
	end
	if value <= 0 then
		return nil, err_invalid(name, name .. " must be positive", value)
	end
	return value, nil
end

local function err_unexpected_response(message, context)
	return {
		code = "UNEXPECTED_RESPONSE",
		message = message,
		recoverable = false,
		context = context,
	}
end

local function wrap_monitoring_cli_error(step, raw_err, ctx)
	local context = {}
	if type(ctx) == "table" then
		for k, v in pairs(ctx) do
			context[k] = v
		end
	end

	local raw_ctx = raw_err and raw_err.context
	if type(raw_ctx) == "table" then
		if raw_ctx.exit_code ~= nil then
			context.exit_code = raw_ctx.exit_code
		end
		if raw_ctx.stderr ~= nil then
			context.stderr = raw_ctx.stderr
		end
		if raw_ctx.stdout ~= nil then
			context.stdout = raw_ctx.stdout
		end
	end

	local detail_parts = {}
	if raw_err and raw_err.message then
		detail_parts[#detail_parts + 1] = tostring(raw_err.message)
	end
	if context.stderr ~= nil then
		detail_parts[#detail_parts + 1] = tostring(context.stderr)
	end
	if context.stdout ~= nil then
		detail_parts[#detail_parts + 1] = tostring(context.stdout)
	end
	local detail_text = table.concat(detail_parts, "\n"):lower()

	if detail_text:find("gcloud auth login", 1, true)
		or detail_text:find("no credentialed accounts", 1, true)
		or detail_text:find("no active account", 1, true)
		or detail_text:find("active account selected", 1, true)
		or detail_text:find("you do not currently have an active account", 1, true) then
		return nil, {
			code = "AUTH_FAILED",
			message = "gcloud authentication is required for " .. step,
			recoverable = true,
			hint = "Run gcloud auth login and verify the active account before retrying.",
			context = context,
		}
	end

	if detail_text:find("not found", 1, true)
		or detail_text:find("was not found", 1, true)
		or detail_text:find("could not be found", 1, true) then
		return nil, {
			code = "RESOURCE_NOT_FOUND",
			message = "Requested Monitoring resource was not found during " .. step,
			recoverable = false,
			hint = "Verify the resource name or use the corresponding list function to discover valid resources.",
			context = context,
		}
	end

	return nil, {
		code = "CLI_ERROR",
		message = "gcloud " .. step .. " failed: " .. ((raw_err and raw_err.message) or tostring(raw_err)),
		recoverable = true,
		hint = "See err.context.stderr for gcloud CLI details. Also verify the project, permissions, and alpha monitoring command availability.",
		context = context,
	}
end

local function run_monitoring_cli_json(args, step, ctx)
	local context = { args = args }
	if type(ctx) == "table" then
		for k, v in pairs(ctx) do
			context[k] = v
		end
	end

	local result, err = raw_cli_json("gcloud", args)
	if err then
		return wrap_monitoring_cli_error(step, err, context)
	end
	return result, nil
end

local function make_cli_array_iterator(result, step, ctx)
	if type(result) ~= "table" then
		return nil, err_unexpected_response("gcloud " .. step .. " response was not an array", ctx)
	end

	for key, _ in pairs(result) do
		if type(key) ~= "number" then
			local context = {}
			if type(ctx) == "table" then
				for k, v in pairs(ctx) do
					context[k] = v
				end
			end
			context.key = key
			context.key_type = type(key)
			return nil, err_unexpected_response("gcloud " .. step .. " response was not an array", context)
		end
	end

	local index = 0
	return function()
		index = index + 1
		local item = result[index]
		if item == nil then
			return nil
		end
		return item, nil
	end, nil
end

local function normalize_monitoring_resource(name, value, opts)
	if value == nil or value == "" then
		return nil, nil, err_required(name, value)
	end
	if type(value) ~= "string" then
		return nil, nil, err_invalid(name, name .. " must be a string", value)
	end
	if value:match("^projects/") then
		return value, nil, nil
	end

	local project, err = validate_project(opts.project)
	if err then return nil, nil, err end
	return value, project, nil
end

local function alert_list(project, opts)
	local err

	project, err = validate_project(project)
	if err then return nil, err end

	opts, err = validate_opts_table(opts)
	if err then return nil, err end

	if opts.filter ~= nil and type(opts.filter) ~= "string" then
		return nil, err_invalid("filter", "filter must be a string", opts.filter)
	end

	local args = {
		"alpha",
		"monitoring",
		"alerts",
		"list",
		"--project=" .. project,
		"--format=json",
	}
	if opts.filter ~= nil and opts.filter ~= "" then
		table.insert(args, "--filter=" .. opts.filter)
	end

	local result
	result, err = run_monitoring_cli_json(args, "alpha monitoring alerts list", {
		project = project,
		filter = opts.filter,
	})
	if err then return nil, err end

	return make_cli_array_iterator(result, "alpha monitoring alerts list", {
		project = project,
		filter = opts.filter,
	})
end

local function alert_describe(alert, opts)
	local err

	opts, err = validate_opts_table(opts)
	if err then return nil, err end

	local alert_name, project
	alert_name, project, err = normalize_monitoring_resource("alert", alert, opts)
	if err then return nil, err end

	local args = {
		"alpha",
		"monitoring",
		"alerts",
		"describe",
		alert_name,
		"--format=json",
	}
	if project ~= nil then
		table.insert(args, "--project=" .. project)
	end

	return run_monitoring_cli_json(args, "alpha monitoring alerts describe", {
		alert = alert_name,
		project = project,
	})
end

local function policy_list(project, opts)
	local err

	project, err = validate_project(project)
	if err then return nil, err end

	opts, err = validate_opts_table(opts)
	if err then return nil, err end

	if opts.filter ~= nil and type(opts.filter) ~= "string" then
		return nil, err_invalid("filter", "filter must be a string", opts.filter)
	end

	local args = {
		"alpha",
		"monitoring",
		"policies",
		"list",
		"--project=" .. project,
		"--format=json",
	}
	if opts.filter ~= nil and opts.filter ~= "" then
		table.insert(args, "--filter=" .. opts.filter)
	end

	local result
	result, err = run_monitoring_cli_json(args, "alpha monitoring policies list", {
		project = project,
		filter = opts.filter,
	})
	if err then return nil, err end

	return make_cli_array_iterator(result, "alpha monitoring policies list", {
		project = project,
		filter = opts.filter,
	})
end

local function policy_describe(policy, opts)
	local err

	opts, err = validate_opts_table(opts)
	if err then return nil, err end

	local policy_name, project
	policy_name, project, err = normalize_monitoring_resource("policy", policy, opts)
	if err then return nil, err end

	local args = {
		"alpha",
		"monitoring",
		"policies",
		"describe",
		policy_name,
		"--format=json",
	}
	if project ~= nil then
		table.insert(args, "--project=" .. project)
	end

	return run_monitoring_cli_json(args, "alpha monitoring policies describe", {
		policy = policy_name,
		project = project,
	})
end

local function descriptor_list(project, opts)
	local err

	project, err = validate_project(project)
	if err then return nil, err end

	opts, err = validate_opts_table(opts)
	if err then return nil, err end

	local auth
	auth, err = get_monitoring_auth()
	if err then
		return nil, {
			code = "AUTH_FAILED",
			message = "Failed to initialize Cloud Monitoring auth",
			recoverable = true,
			hint = err.hint,
			context = { cause = err.message or tostring(err) },
		}
	end

	local query = {}
	if opts.filter ~= nil then
		if type(opts.filter) ~= "string" then
			return nil, err_invalid("filter", "filter must be a string", opts.filter)
		end
		if opts.filter ~= "" then
			query.filter = opts.filter
		end
	end

	if opts.active_only ~= nil then
		if type(opts.active_only) ~= "boolean" then
			return nil, err_invalid("active_only", "active_only must be a boolean", opts.active_only)
		end
		query.activeOnly = opts.active_only
	end

	local per_page, per_page_err = coerce_positive_number("per_page", opts.per_page)
	if per_page_err then return nil, per_page_err end

	local limit, limit_err = coerce_positive_number("limit", opts.limit)
	if limit_err then return nil, limit_err end

	return raw_http_list("GET", MONITORING_BASE_URL, "/v3/projects/" .. project .. "/metricDescriptors", {
		auth = auth,
		query = query,
		pagination = {
			kind = "token",
			items_path = "metricDescriptors",
			token_param = "pageToken",
			limit_param = "pageSize",
			next_token_path = "nextPageToken",
			missing_items_as_empty = true,
		},
		per_page = per_page,
		limit = limit,
	})
end

local function series_list(project, opts)
	local err

	project, err = validate_project(project)
	if err then return nil, err end

	opts, err = validate_opts_table(opts)
	if err then return nil, err end

	if type(opts.filter) ~= "string" or opts.filter == "" then
		return nil, err_required("filter", opts.filter)
	end

	local interval = opts.interval
	if type(interval) ~= "table" then
		return nil, {
			code = "MISSING_REQUIRED_FIELD",
			message = "interval table is required",
			recoverable = false,
			context = { interval = interval },
		}
	end

	local start_time = interval.start_time or interval.startTime
	local end_time = interval.end_time or interval.endTime

	local ok, reason = validate_rfc3339ish("interval.start_time", start_time)
	if not ok then return nil, err_invalid("interval.start_time", reason, start_time) end

	ok, reason = validate_rfc3339ish("interval.end_time", end_time)
	if not ok then return nil, err_invalid("interval.end_time", reason, end_time) end

	local auth
	auth, err = get_monitoring_auth()
	if err then
		return nil, {
			code = "AUTH_FAILED",
			message = "Failed to initialize Cloud Monitoring auth",
			recoverable = true,
			hint = err.hint,
			context = { cause = err.message or tostring(err) },
		}
	end

	local query = {
		filter = opts.filter,
		["interval.startTime"] = start_time,
		["interval.endTime"] = end_time,
	}

	if opts.view ~= nil then
		if type(opts.view) ~= "string" or opts.view == "" then
			return nil, err_invalid("view", "view must be a non-empty string", opts.view)
		end
		query.view = opts.view
	end

	if opts.aggregation ~= nil then
		if type(opts.aggregation) ~= "table" then
			return nil, err_invalid("aggregation", "aggregation must be a table", opts.aggregation)
		end
		if opts.aggregation.alignment_period ~= nil then
			if type(opts.aggregation.alignment_period) ~= "string" or opts.aggregation.alignment_period == "" then
				return nil, err_invalid("aggregation.alignment_period", "must be a non-empty string", opts.aggregation.alignment_period)
			end
			query["aggregation.alignmentPeriod"] = opts.aggregation.alignment_period
		end
		if opts.aggregation.per_series_aligner ~= nil then
			if type(opts.aggregation.per_series_aligner) ~= "string" or opts.aggregation.per_series_aligner == "" then
				return nil, err_invalid("aggregation.per_series_aligner", "must be a non-empty string", opts.aggregation.per_series_aligner)
			end
			query["aggregation.perSeriesAligner"] = opts.aggregation.per_series_aligner
		end
	end

	local per_page, per_page_err = coerce_positive_number("per_page", opts.per_page)
	if per_page_err then return nil, per_page_err end

	local limit, limit_err = coerce_positive_number("limit", opts.limit)
	if limit_err then return nil, limit_err end

	return raw_http_list("GET", MONITORING_BASE_URL, "/v3/projects/" .. project .. "/timeSeries", {
		auth = auth,
		query = query,
		pagination = {
			kind = "token",
			items_path = "timeSeries",
			token_param = "pageToken",
			limit_param = "pageSize",
			next_token_path = "nextPageToken",
			missing_items_as_empty = true,
		},
		per_page = per_page,
		limit = limit,
	})
end

gcloud.monitoring.alert.list = alert_list
gcloud.monitoring.alert.describe = alert_describe
gcloud.monitoring.policy.list = policy_list
gcloud.monitoring.policy.describe = policy_describe
gcloud.monitoring.descriptor.list = descriptor_list
gcloud.monitoring.series.list = series_list

gcloud.monitoring.alert.__schema = {
	namespace = "gcloud.monitoring.alert",
	service = "gcloud",
	summary = "Cloud Monitoring alert operations",
	functions = {
		{
			name = "list",
			path = "gcloud.monitoring.alert.list",
			signature = "(project, opts?)",
			description = "List Cloud Monitoring alerts via gcloud alpha monitoring alerts list.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "Alert",
			params = {
				{ name = "project", type = "string", optional = false, description = "GCP project ID" },
				{ name = "opts", type = "table", optional = true, description = "Optional gcloud list filter", schema = {
					filter = { type = "string", optional = true, description = "gcloud filter expression, e.g. state='OPEN'" },
				} },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
local iter = gcloud.monitoring.alert.list("my-project", {
  filter = "state='OPEN'",
})
local alerts, err = helpers.collect(iter, { limit = 5 })
if err then error(err.message or tostring(err)) end
return alerts
]],
		},
		{
			name = "describe",
			path = "gcloud.monitoring.alert.describe",
			signature = "(alert, opts?)",
			description = "Describe a Cloud Monitoring alert via gcloud alpha monitoring alerts describe. Accepts a fully qualified alert resource name, or a short alert ID when opts.project is provided.",
			readonly = true,
			returns_contract = "core.result",
			params = {
				{ name = "alert", type = "string", optional = false, description = "Alert ID or fully qualified alert resource name" },
				{ name = "opts", type = "table", optional = true, description = "Optional project for short alert IDs", schema = {
					project = { type = "string", optional = true, description = "GCP project ID required when alert is not fully qualified" },
				} },
			},
			returns_typed = {
				{ name = "result", type = "Alert" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
local alert, err = gcloud.monitoring.alert.describe(
  "projects/my-project/alerts/1234567890"
)
if err then error(err.message or tostring(err)) end
return alert
]],
		},
	},
	types = {
		Alert = {
			description = "Cloud Monitoring alert returned by gcloud alpha monitoring alerts commands.",
			shape = "{name?:string, state?:string, openTime?:string, closeTime?:string, summary?:string, policy?:table, resource?:table, ...}",
		},
	},
}

gcloud.monitoring.policy.__schema = {
	namespace = "gcloud.monitoring.policy",
	service = "gcloud",
	summary = "Cloud Monitoring alerting policy operations",
	functions = {
		{
			name = "list",
			path = "gcloud.monitoring.policy.list",
			signature = "(project, opts?)",
			description = "List Cloud Monitoring alerting policies via gcloud alpha monitoring policies list.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "AlertPolicy",
			params = {
				{ name = "project", type = "string", optional = false, description = "GCP project ID" },
				{ name = "opts", type = "table", optional = true, description = "Optional gcloud list filter", schema = {
					filter = { type = "string", optional = true, description = "gcloud filter expression for alerting policies" },
				} },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
local iter = gcloud.monitoring.policy.list("my-project", {
  filter = "NOT display_name.empty",
})
local policies, err = helpers.collect(iter, { limit = 5 })
if err then error(err.message or tostring(err)) end
return policies
]],
		},
		{
			name = "describe",
			path = "gcloud.monitoring.policy.describe",
			signature = "(policy, opts?)",
			description = "Describe a Cloud Monitoring alerting policy via gcloud alpha monitoring policies describe. Accepts a fully qualified policy resource name, or a short policy ID when opts.project is provided.",
			readonly = true,
			returns_contract = "core.result",
			params = {
				{ name = "policy", type = "string", optional = false, description = "Policy ID or fully qualified policy resource name" },
				{ name = "opts", type = "table", optional = true, description = "Optional project for short policy IDs", schema = {
					project = { type = "string", optional = true, description = "GCP project ID required when policy is not fully qualified" },
				} },
			},
			returns_typed = {
				{ name = "result", type = "AlertPolicy" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
local policy, err = gcloud.monitoring.policy.describe(
  "projects/my-project/alertPolicies/1234567890"
)
if err then error(err.message or tostring(err)) end
return policy
]],
		},
	},
	types = {
		AlertPolicy = {
			description = "Cloud Monitoring alerting policy returned by gcloud alpha monitoring policies commands.",
			shape = "{name?:string, displayName?:string, display_name?:string, documentation?:table, conditions?:table, notificationChannels?:table, userLabels?:table, ...}",
		},
	},
}

gcloud.monitoring.descriptor.__schema = {
	namespace = "gcloud.monitoring.descriptor",
	service = "gcloud",
	summary = "Cloud Monitoring metric descriptor operations",
	functions = {
		{
			name = "list",
			path = "gcloud.monitoring.descriptor.list",
			signature = "(project, opts?)",
			description = "List Cloud Monitoring metric descriptors using the Monitoring REST API and gcloud-generated bearer auth.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "MetricDescriptor",
			params = {
				{ name = "project", type = "string", optional = false, description = "GCP project ID" },
				{ name = "opts", type = "table", optional = true, description = "Optional filters/config", schema = {
					filter = { type = "string", optional = true, description = "Monitoring filter expression for descriptors" },
					active_only = { type = "boolean", optional = true, description = "If true, return only active descriptors" },
					per_page = { type = "number", optional = true, description = "Requested API page size" },
					limit = { type = "number", optional = true, description = "Maximum number of descriptors to yield" },
				} },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
local iter = gcloud.monitoring.descriptor.list("my-project", {
  filter = 'metric.type = starts_with("compute.googleapis.com")',
  limit = 5,
})
local items, err = helpers.collect(iter, { limit = 5 })
if err then error(err.message or tostring(err)) end
return items
]],
		},
	},
	types = {
		MetricDescriptor = {
			description = "Cloud Monitoring metric descriptor",
			shape = "{name:string, type:string, metricKind?:string, valueType?:string, displayName?:string, description?:string, labels?:table, unit?:string, ...}",
		},
	},
}

gcloud.monitoring.series.__schema = {
	namespace = "gcloud.monitoring.series",
	service = "gcloud",
	summary = "Cloud Monitoring time series operations",
	functions = {
		{
			name = "list",
			path = "gcloud.monitoring.series.list",
			signature = "(project, opts)",
			description = "List Cloud Monitoring time series using the Monitoring REST API and gcloud-generated bearer auth. Empty API responses without a timeSeries field are treated as successful empty result sets.",
			readonly = true,
			returns_contract = "core.iter",
			yields = "TimeSeries",
			params = {
				{ name = "project", type = "string", optional = false, description = "GCP project ID" },
				{ name = "opts", type = "table", optional = false, description = "Required query options", schema = {
					filter = { type = "string", optional = false, description = "Monitoring filter expression, e.g. metric.type=\"compute.googleapis.com/instance/cpu/utilization\"" },
					interval = { type = "table", optional = false, description = "Time interval", schema = {
						start_time = { type = "string", optional = false, description = "RFC3339 start time" },
						end_time = { type = "string", optional = false, description = "RFC3339 end time" },
					} },
					view = { type = "string", optional = true, description = "Monitoring time series view, e.g. FULL or HEADERS" },
					aggregation = { type = "table", optional = true, description = "Optional partial aggregation config", schema = {
						alignment_period = { type = "string", optional = true, description = "Alignment period, e.g. 60s" },
						per_series_aligner = { type = "string", optional = true, description = "Per-series aligner enum string" },
					} },
					per_page = { type = "number", optional = true, description = "Requested API page size" },
					limit = { type = "number", optional = true, description = "Maximum number of series to yield" },
				} },
			},
			returns_typed = {
				{ name = "iterator", type = "Iterator" },
			},
			examples = [[
local function point_number(point)
  local value = (point and point.value) or {}
  if value.doubleValue ~= nil then return tonumber(value.doubleValue), "doubleValue" end
  if value.int64Value ~= nil then return tonumber(value.int64Value), "int64Value" end
  if value.distributionValue ~= nil then return nil, "distributionValue" end
  return nil, "unknown"
end

-- CUMULATIVE CPU metric: ALIGN_RATE is usually the right aligner.
local iter = gcloud.monitoring.series.list("my-project", {
  filter = 'metric.type="kubernetes.io/container/cpu/core_usage_time" AND resource.labels.namespace_name="default"',
  interval = {
    start_time = "2026-03-23T10:00:00Z",
    end_time = "2026-03-23T11:00:00Z",
  },
  view = "FULL",
  aggregation = {
    alignment_period = "60s",
    per_series_aligner = "ALIGN_RATE",
  },
  limit = 3,
})

local series, err = helpers.collect(iter, { limit = 3 })
if err then error(err.message or tostring(err)) end
if #series == 0 then return { count = 0, note = "no matching time series" } end

local point = (((((series[1] or {})[1] or {}).points or {})[1]))
local value, kind = point_number(point)
return { count = #series, first_value = value, value_kind = kind }
]],
		},
	},
	types = {
		TimeSeries = {
			description = "Cloud Monitoring time series. point values are typed; inspect points[].value.doubleValue, int64Value, distributionValue, etc. depending on metric type.",
			shape = "{metric?:table, resource?:table, metricKind?:string, valueType?:string, unit?:string, points?:Point[], metadata?:table, ...}",
		},
		Point = {
			description = "Cloud Monitoring point in a time series.",
			shape = "{interval?:table, value?:TypedValue, ...}",
		},
		TypedValue = {
			description = "Typed metric point value. Use doubleValue for floating-point gauges/rates, int64Value for integer counters/gauges, and distributionValue for distribution metrics.",
			shape = "{doubleValue?:number, int64Value?:string|number, distributionValue?:table, boolValue?:boolean, stringValue?:string, ...}",
		},
	},
}
