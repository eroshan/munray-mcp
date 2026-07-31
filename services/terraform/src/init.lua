-- preload/terraform.lua
-- Terraform helpers (plan parsing)

terraform = terraform or {}

terraform.__intro = [[
Use this service for parsing Terraform and Terragrunt plan output.
Prefer complete plan logs so the parser can preserve summaries, resource changes, and error details.
]]

terraform.__schema = {
	namespace = "terraform",
	service = "terraform",
	description = "Terraform utilities and log parsing",
	functions = {
		{
			name = "parse_plan",
			path = "terraform.parse_plan",
			signature = "(log)",
			returns_contract = "core.result",
			mutating = false,
			description = "Parse Terraform plan output into structured summary, resource changes, and diagnostics",
			params = { { name = "log", type = "string" } },
			returns_typed = {
				{ name = "result", type = "PlanParseResult" },
				{ name = "err", type = "core.error|nil" },
			},
		},
	},
	types = {
		PlanParseResult = {
			description = "Structured Terraform plan parse result",
			shape = "{summary:PlanSummary, module_plans:PlanSummary[], summary_sources:{wrapper:PlanSummary|nil, plan_last:PlanSummary|nil}, summary_inconsistent:boolean, resources_to_add:ResourceChange[], resources_to_change:ResourceChange[], resources_to_destroy:ResourceChange[], errors:string[], warnings:string[], has_replacements:boolean, raw_plan:string}",
		},
		PlanSummary = { description = "Aggregated plan totals", shape = "{add:number, change:number, destroy:number}" },
		ResourceChange = {
			description = "Single resource change entry",
			shape = "{full_name:string, type:string, name:string, change_type?:string}",
		},
	},
}

-- terraform.parse_plan(log) -> result, err
-- Parses Terraform plan or terragrunt plan output into structured data
function terraform.parse_plan(log)
	if not log or log == "" then
		return nil, { code = "VALIDATION", message = "log is empty or nil", recoverable = false }
	end

	local result = {
		summary = { add = 0, change = 0, destroy = 0 },
		module_plans = {},
		summary_sources = { wrapper = nil, plan_last = nil },
		summary_inconsistent = false,
		resources_to_add = {},
		resources_to_change = {},
		resources_to_destroy = {},
		errors = {},
		warnings = {},
		has_replacements = false,
		raw_plan = ""
	}

	local function strip_ansi_all(s)
		-- remove CSI (covers m, K, etc) and OSC
		s = s:gsub("\027%[[0-9;?]*[ -/]*[@-~]", "")
		s = s:gsub("\027%][^\007]*\007", "")
		return s
	end

	local clean = strip_ansi_all(log):gsub("\r\n", "\n"):gsub("\r", "\n")

	local function resource_type_name(addr)
		local s = addr
		-- Strip module.* prefixes
		while s:match("^module%.[^.]+%.") do
			s = s:gsub("^module%.[^.]+%.", "")
		end

		-- Handle data sources: data.TYPE.NAME
		if s:match("^data%.") then
			local dtype, dname = s:match("^data%.([^%.]+)%.([^%.]+)$")
			if dtype and dname then
				return dtype, dname
			end
		end

		-- Standard resource: TYPE.NAME
		local rtype, rname = s:match("([^%.]+)%.([^%.]+)$")
		return rtype or "", rname or s
	end

	-- Authoritative wrapper summary (Terragrunt / wrapper output)
	local w_add = clean:match("Resources to create:%s*(%d+)")
	local w_change = clean:match("Resources to update[^:]*:%s*(%d+)")
	local w_destroy = clean:match("Resources to destroy:%s*(%d+)")
	local wrapper = nil
	if w_add or w_change or w_destroy then
		wrapper = {
			add = tonumber(w_add or "0"),
			change = tonumber(w_change or "0"),
			destroy = tonumber(w_destroy or "0"),
		}
		result.summary = wrapper
	end

	-- Extract raw plan: capture ALL plan sections (supports multi-module terragrunt runs)
	-- Filter out lines starting with "=>" (module dependency markers)
	local plan_lines = {}
	local in_plan = false

	for line in clean:gmatch("[^\n]+") do
		local cleaned = line

		-- Start of a plan section (resource marker or "Terraform will perform")
		if cleaned:match("^%s*#%s+[a-z_]+%.") or cleaned:match("Terraform will perform") then
			in_plan = true
		end

		-- If we hit a Plan summary, include it and continue (might be more modules)
		if cleaned:match("^Plan: %d+") then
			table.insert(plan_lines, cleaned)
			table.insert(plan_lines, "") -- blank line separator
			in_plan = false
			goto continue
		end

		-- Capture plan lines, excluding "=>" module dependency markers
		if in_plan and not cleaned:match("^%s*=>") and not cleaned:match("^%s*$") then
			table.insert(plan_lines, cleaned)
		end

		::continue::
	end

	result.raw_plan = table.concat(plan_lines, "\n")

	-- Parse Plan: lines (module-level totals). Do not override wrapper summary.
	for line in clean:gmatch("[^\n]+") do
		local add = line:match("^Plan:%s+(%d+)%s+to add")
		if add then
			table.insert(result.module_plans, {
				add = tonumber(add or "0"),
				change = tonumber(line:match("(%d+)%s+to change") or "0"),
				destroy = tonumber(line:match("(%d+)%s+to destroy") or "0"),
			})
		end
	end

	-- If no wrapper summary, fall back to last Plan: line (simplest and matches prior behavior)
	if not wrapper and #result.module_plans > 0 then
		result.summary = result.module_plans[#result.module_plans]
	end

	local plan_last = (#result.module_plans > 0) and result.module_plans[#result.module_plans] or nil
	result.summary_sources = { wrapper = wrapper, plan_last = plan_last }
	result.summary_inconsistent =
		(wrapper and plan_last)
			and (wrapper.add ~= plan_last.add or wrapper.change ~= plan_last.change or wrapper.destroy ~= plan_last.destroy)
			or false

	-- Parse resources to be created/updated/destroyed (use normalized clean log)
	for line in clean:gmatch("[^\n]+") do
		local resource = line:match("#%s+([^%s]+)%s+will be created")
		if resource then
			local resource_type, resource_name = resource_type_name(resource)
			table.insert(result.resources_to_add, {
				full_name = resource,
				type = resource_type,
				name = resource_name,
			})
		end

		resource = line:match("#%s+([^%s]+)%s+will be updated")
		if resource and line:match("will be updated in%-place") then
			local resource_type, resource_name = resource_type_name(resource)
			table.insert(result.resources_to_change, {
				full_name = resource,
				type = resource_type,
				name = resource_name,
				change_type = "in-place",
			})
		end

		resource = line:match("#%s+([^%s]+)%s+will be destroyed")
		if resource then
			local resource_type, resource_name = resource_type_name(resource)
			table.insert(result.resources_to_destroy, {
				full_name = resource,
				type = resource_type,
				name = resource_name,
			})
		end
	end

	-- Check for resource replacements
	result.has_replacements = clean:match("must be replaced") ~= nil

	-- Extract Terraform errors (capture header + a few context lines)
	local lines = {}
	for line in clean:gmatch("[^\n]*\n?") do
		if line == "" then
			break
		end
		line = line:gsub("\n$", "")
		table.insert(lines, line)
	end

	local i = 1
	while i <= #lines do
		local line = lines[i]
		if line:match("Error:") then
			local msg_lines = { line }
			for j = i + 1, math.min(i + 8, #lines) do
				local nxt = lines[j]
				if not nxt or nxt:match("^%s*$") then
					break
				end
				table.insert(msg_lines, nxt)
			end
			local msg = table.concat(msg_lines, "\n")
			if not msg:match("^%s*$") then
				table.insert(result.errors, msg)
			end
		end
		i = i + 1
	end

	-- Extract warnings (filter SSH and CI noise) with de-dupe
	local seen_warning = {}
	for line in clean:gmatch("[^\n]+") do
		if line:match("Warning:") then
			if not line:match("Permanently added") and
				not line:match("known hosts") and
				not line:match("^%s*$") then
				if not seen_warning[line] then
					seen_warning[line] = true
					table.insert(result.warnings, line)
				end
			end
		end
	end

	return result, nil
end
