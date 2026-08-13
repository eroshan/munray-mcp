-- preload/errutil.lua
-- Internal error translation helpers for service-pack authors.
-- This namespace intentionally has no __schema and is not discoverable.

errutil = {}

local PUBLIC_MARKER = "__mcp_server_public"

local policies = {}

local forbidden_context_keys = {
	tool = true,
	args = true,
	stderr = true,
	stdout = true,
	exit_code = true,
	cause = true,
	upstream_code = true,
}

local code_map = {
	CLI_ERROR = "UPSTREAM_ERROR",
	HTTP_ERROR = "UPSTREAM_ERROR",
	ITERATOR_ERROR = "ITERATION_FAILED",
	ITERATOR_PANIC = "ITERATION_FAILED",
}

local function error_table(code, message)
	return {
		code = code,
		message = message,
		recoverable = false,
	}
end

local function default_message_for_code(code)
	if code == "ITERATION_FAILED" then
		return "Iteration failed"
	end

	return "Upstream request failed"
end

local function normalize_code(code)
	if type(code) ~= "string" or code == "" then
		return "UPSTREAM_ERROR"
	end

	return code_map[code] or code
end

local function sanitize_context(value, seen)
	if type(value) ~= "table" then
		return value
	end

	seen = seen or {}
	if seen[value] ~= nil then
		return seen[value]
	end

	local out = {}
	seen[value] = out

	for k, v in pairs(value) do
		if not (type(k) == "string" and forbidden_context_keys[k]) then
			out[k] = sanitize_context(v, seen)
		end
	end

	return out
end

local function is_public(err)
	if type(err) ~= "table" then
		return false
	end

	local mt = getmetatable(err)
	return type(mt) == "table" and mt[PUBLIC_MARKER] == true
end

local function make_public_error(spec)
	spec = spec or {}

	local original_code = spec.code
	local code = normalize_code(original_code)
	local message
	if code ~= original_code then
		message = default_message_for_code(code)
	elseif type(spec.message) == "string" and spec.message ~= "" then
		message = spec.message
	else
		message = default_message_for_code(code)
	end

	local err = {
		code = code,
		message = message,
		recoverable = spec.recoverable == true,
	}

	local hint = spec.hint
	if type(hint) ~= "string" or hint == "" then
		hint = spec.suggestion
	end
	if type(hint) == "string" and hint ~= "" then
		err.hint = hint
	end

	if type(spec.context) == "table" then
		local ctx = sanitize_context(spec.context, {})
		if next(ctx) ~= nil then
			err.context = ctx
		end
	end

	local mt = getmetatable(err) or {}
	mt.__tostring = function(e)
		return e.message or "error"
	end
	mt[PUBLIC_MARKER] = true
	setmetatable(err, mt)

	return err
end

local function build_public_context(policy, raw_err, meta)
	if type(policy) == "table" and type(policy.public_context) == "function" then
		local ctx = policy.public_context(raw_err, meta)
		if type(ctx) == "table" then
			return ctx
		end
		return nil
	end

	if type(policy) ~= "table" or type(policy.public_context_allowlist) ~= "table" then
		return nil
	end
	if type(meta) ~= "table" or type(meta.public_context) ~= "table" then
		return nil
	end

	local out = {}
	for k, v in pairs(meta.public_context) do
		if policy.public_context_allowlist[k] then
			out[k] = v
		end
	end

	if next(out) == nil then
		return nil
	end

	return out
end

local function default_fallback(_service, raw_err, meta)
	local recoverable = false
	if type(raw_err) == "table" and type(raw_err.recoverable) == "boolean" then
		recoverable = raw_err.recoverable
	end

	if type(meta) == "table" and meta.kind == "list" then
		return {
			code = "ITERATION_FAILED",
			message = "Iteration failed",
			recoverable = recoverable,
		}
	end

	return {
		code = "UPSTREAM_ERROR",
		message = "Upstream request failed",
		recoverable = recoverable,
	}
end

function errutil.is_public(err)
	return is_public(err)
end

function errutil.register_policy(service, policy)
	if type(service) ~= "string" or service == "" then
		return nil, error_table("VALIDATION", "errutil.register_policy: service must be a non-empty string")
	end
	if type(policy) ~= "table" then
		return nil, error_table("VALIDATION", "errutil.register_policy: policy must be a table")
	end
	if policies[service] ~= nil then
		return nil, error_table("ALREADY_EXISTS", "errutil.register_policy: policy already registered for service '" .. service .. "'")
	end

	policies[service] = policy
	return true, nil
end

function errutil.for_service(service)
	return {
		public = function(spec)
			return make_public_error(spec)
		end,
		from_upstream = function(raw_err, meta)
			if is_public(raw_err) then
				return raw_err
			end

			local policy = policies[service] or {}
			local chosen = nil
			if type(policy.classify) == "function" then
				chosen = policy.classify(raw_err, meta)
			end

			if chosen == nil then
				if type(policy.fallback) == "function" then
					chosen = policy.fallback(raw_err, meta)
				elseif type(policy.fallback) == "table" then
					chosen = policy.fallback
				end
			end

			if chosen == nil then
				chosen = default_fallback(service, raw_err, meta)
			end

			if is_public(chosen) then
				return chosen
			end

			if type(chosen) ~= "table" then
				chosen = default_fallback(service, raw_err, meta)
			end

			local spec = {}
			for k, v in pairs(chosen) do
				spec[k] = v
			end

			if spec.context == nil then
				spec.context = build_public_context(policy, raw_err, meta)
			end

			if spec.recoverable == nil then
				if type(raw_err) == "table" and type(raw_err.recoverable) == "boolean" then
					spec.recoverable = raw_err.recoverable
				else
					spec.recoverable = false
				end
			end

			return make_public_error(spec)
		end,
		is_public = function(err)
			return is_public(err)
		end,
	}
end

function errutil.coerce_public(err, fallback_spec)
	if is_public(err) then
		return err
	end

	local spec = {}
	if type(fallback_spec) == "table" then
		for k, v in pairs(fallback_spec) do
			spec[k] = v
		end
	end

	if spec.recoverable == nil then
		if type(err) == "table" and type(err.recoverable) == "boolean" then
			spec.recoverable = err.recoverable
		else
			spec.recoverable = false
		end
	end

	return make_public_error(spec)
end
