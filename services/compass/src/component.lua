-- luacheck: globals compass

local client = compass._get_client()
if client == nil then
	error("compass client not initialized")
end
local validation_err = client.validation_err

local function invalid_field_value_err(field_name, value, extra)
	local context = { field = field_name, value = value }
	for k, v in pairs(extra or {}) do
		context[k] = v
	end
	return {
		code = "INVALID_FIELD_VALUE",
		message = "Invalid value for field '" .. tostring(field_name) .. "'",
		context = context,
		recoverable = false,
	}
end

local missing_field_err = client.missing_field_err

local function make_error_iterator(err)
	return function()
		error(err, 0)
	end
end

local function normalize_scalar_id(value, field_name)
	if value == nil then
		return nil, missing_field_err(field_name)
	end
	if type(value) == "string" then
		if value == "" then
			return nil, missing_field_err(field_name)
		end
		return value, nil
	end
	if type(value) == "number" then
		return tostring(value), nil
	end
	return nil, invalid_field_value_err(field_name, value, { value_type = type(value) })
end

local function normalize_id_list(ids)
	if type(ids) ~= "table" then
		return nil, validation_err("ids must be an array", { ids_type = type(ids) })
	end
	if #ids == 0 then
		return nil, validation_err("ids must not be empty", {})
	end
	if #ids > 30 then
		return nil, validation_err("ids must contain at most 30 entries", { count = #ids, max = 30 })
	end

	local out = {}
	for i, value in ipairs(ids) do
		local normalized, err = normalize_scalar_id(value, "ids[" .. i .. "]")
		if err then
			return nil, err
		end
		out[i] = normalized
	end

	return out, nil
end

local function validate_field_set(field_set)
	if field_set == nil or field_set == "" then
		return "default", nil
	end
	if field_set == "default" or field_set == "minimal" or field_set == "full" then
		return field_set, nil
	end
	return nil, invalid_field_value_err("field_set", field_set)
end

local function custom_fields_selection()
	return [[
		customFields {
			__typename
			definition {
				id
				name
				description
			}
			... on CompassCustomUserField {
				userIdValue
				userValue {
					__typename
					... on AtlassianAccountUser {
						accountId
						name
					}
				}
			}
		}
	]]
end

local function component_fields(field_set)
	if field_set == "minimal" then
		return [[
			id
			typeId
			name
			slug
			url
		]]
	end

	local parts = {
		[[
		id
		typeId
		name
		slug
		url
		description
		state
		ownerId
		labels {
			name
		}
		links {
			type
			url
			name
		}
		]],
	}

	if field_set == "full" then
		parts[#parts + 1] = custom_fields_selection()
	end

	return table.concat(parts, "\n")
end

local function validate_selection(selection, field_name)
	if selection == nil then
		return nil
	end
	if type(selection) ~= "table" then
		return invalid_field_value_err(field_name, selection, { value_type = type(selection) })
	end

	for i, item in ipairs(selection) do
		local item_field = field_name .. "[" .. i .. "]"
		if type(item) == "string" then
			if item == "" then
				return invalid_field_value_err(item_field, item, { reason = "empty_string" })
			end
		elseif type(item) == "table" then
			local has_name = type(item.name) == "string" and item.name ~= ""
			local has_fragment = type(item.on) == "string" and item.on ~= ""
			if has_name == has_fragment then
				return validation_err("selection entries must define exactly one of 'name' or 'on'", { field = item_field })
			end
			if item.fields ~= nil then
				local nested_err = validate_selection(item.fields, item_field .. ".fields")
				if nested_err then
					return nested_err
				end
			end
		else
			return invalid_field_value_err(item_field, item, { value_type = type(item) })
		end
	end

	return nil
end

local function render_selection(selection, indent)
	indent = indent or 0
	local prefix = string.rep("\t", indent)
	local lines = {}

	for _, item in ipairs(selection or {}) do
		if type(item) == "string" then
			lines[#lines + 1] = prefix .. item
		elseif type(item) == "table" then
			local head = item.name
			if head == nil then
				head = "... on " .. item.on
			end
			if item.fields ~= nil and #item.fields > 0 then
				lines[#lines + 1] = prefix .. head .. " {"
				lines[#lines + 1] = render_selection(item.fields, indent + 1)
				lines[#lines + 1] = prefix .. "}"
			else
				lines[#lines + 1] = prefix .. head
			end
		end
	end

	return table.concat(lines, "\n")
end

local function parse_component_selection(selection)
	if type(selection) == "string" then
		return nil, validation_err("selection must be a structured array of fields", { field = "selection" })
	end
	local err = validate_selection(selection, "selection")
	if err then
		return nil, err
	end
	return render_selection(selection), nil
end

local function component_selection(field_set, opts)
	opts = opts or {}

	if opts.include_custom_fields ~= nil and type(opts.include_custom_fields) ~= "boolean" then
		return nil, invalid_field_value_err("include_custom_fields", opts.include_custom_fields, { value_type = type(opts.include_custom_fields) })
	end

	if opts.selection ~= nil then
		if opts.field_set ~= nil or opts.include_custom_fields ~= nil or opts.extra_selection ~= nil then
			return nil, validation_err("selection cannot be combined with field_set, include_custom_fields, or extra_selection", {})
		end
		return parse_component_selection(opts.selection)
	end

	local parts = { component_fields(field_set) }
	if opts.include_custom_fields == true and field_set ~= "full" then
		parts[#parts + 1] = custom_fields_selection()
	end

	if opts.extra_selection ~= nil then
		local extra, extra_err = parse_component_selection(opts.extra_selection)
		if extra_err then
			return nil, extra_err
		end
		if extra ~= nil and extra ~= "" then
			parts[#parts + 1] = extra
		end
	end

	return table.concat(parts, "\n"), nil
end


local function component_log_fields(field_set)
	if field_set == "minimal" then
		return [[
			id
			action
			timestamp
			value
		]]
	end

	return [[
		id
		action
		actor
		componentId
		discoveryStrategy
		fieldId
		source
		timestamp
		value
	]]
end

local function extract_path(root, path)
	local current = root
	for part in string.gmatch(path, "[^%.]+") do
		if type(current) ~= "table" then
			return nil
		end
		current = current[part]
		if current == nil then
			return nil
		end
	end
	return current
end

local function append_field_filter(filters, name, filter)
	if filter == nil then
		return
	end
	filters[#filters + 1] = {
		name = name,
		filter = filter,
	}
end

local function ensure_string_array(value, field_name)
	if type(value) ~= "table" then
		return nil, invalid_field_value_err(field_name, value, { value_type = type(value) })
	end

	local out = {}
	for i, item in ipairs(value) do
		if type(item) == "string" then
			if item == "" then
				return nil, invalid_field_value_err(field_name, item, { index = i, reason = "empty_string" })
			end
			out[#out + 1] = item
		elseif type(item) == "number" then
			out[#out + 1] = tostring(item)
		else
			return nil, invalid_field_value_err(field_name, item, { index = i, value_type = type(item) })
		end
	end

	return out, nil
end

local function validate_sort(sort)
	if sort == nil then
		return nil
	end
	if type(sort) ~= "string" then
		return invalid_field_value_err("sort", sort, { value_type = type(sort) })
	end
	if sort == "" then
		return invalid_field_value_err("sort", sort, { reason = "empty_string" })
	end
	return nil
end

local function search_query_input(query, opts)
	opts = opts or {}

	local sort_err = validate_sort(opts.sort)
	if sort_err then
		return nil, sort_err
	end

	if type(query) == "string" then
		if query == "" then
			return nil, missing_field_err("query")
		end
		return {
			query = {
				query = query,
				first = opts.per_page,
				after = nil,
				sort = opts.sort,
			},
		}, nil
	end
	if type(query) ~= "table" then
		return nil, validation_err("query must be a string or table", { query_type = type(query) })
	end

	local field_filters = {}
	if query.ownerId ~= nil then
		append_field_filter(field_filters, "ownerId", { eq = tostring(query.ownerId) })
	end
	if query.typeId ~= nil then
		append_field_filter(field_filters, "type", { eq = tostring(query.typeId) })
	end
	if query.labels ~= nil then
		local labels, labels_err = ensure_string_array(query.labels, "query.labels")
		if labels_err then
			return nil, labels_err
		end
		append_field_filter(field_filters, "labels", { ["in"] = labels })
	end
	if query.state ~= nil then
		append_field_filter(field_filters, "state", { eq = tostring(query.state) })
	end

	local query_text = query.text
	if query_text == "" then
		query_text = nil
	end
	if query_text ~= nil and type(query_text) ~= "string" then
		return nil, invalid_field_value_err("query.text", query_text, { value_type = type(query_text) })
	end

	local out = {
		query = {
			query = query_text,
			first = opts.per_page,
			after = nil,
			sort = opts.sort,
		},
	}
	if #field_filters > 0 then
		out.query.fieldFilters = field_filters
	end

	return out, nil
end

function compass.ready()
	local data, err = client.request([[query CompassReady {
		compass {
			__typename
		}
	}]], nil, {
		operation_name = "CompassReady",
	})
	if err then
		return false, err
	end

	if type(data) ~= "table" or type(data.compass) ~= "table" then
		return false, validation_err("Compass ready check returned an unexpected response shape", {})
	end

	return true, nil
end

function compass.components(ids, opts)
	opts = opts or {}

	local normalized_ids, ids_err = normalize_id_list(ids)
	if ids_err then
		return nil, ids_err
	end

	local field_set, field_err = validate_field_set(opts.field_set)
	if field_err then
		return nil, field_err
	end

	local selection, selection_err = component_selection(field_set, opts)
	if selection_err then
		return nil, selection_err
	end

	local data, err = client.request(string.format([[query CompassComponents($ids: [ID!]!) {
		compass {
			components(ids: $ids) {
				__typename
				... on CompassComponent {
%s
				}
			}
		}
	}]], selection), {
		ids = normalized_ids,
	}, {
		operation_name = "CompassComponents",
		experimental_apis = opts.experimental_apis,
		response_mode = opts.response_mode,
	})
	if err then
		return nil, err
	end

	if opts.response_mode == "envelope" then
		return data, nil
	end

	return extract_path(data, "compass.components"), nil
end

function compass.component(id, opts)
	opts = opts or {}

	local normalized_id, id_err = normalize_scalar_id(id, "id")
	if id_err then
		return nil, id_err
	end

	local field_set, field_err = validate_field_set(opts.field_set)
	if field_err then
		return nil, field_err
	end

	local selection, selection_err = component_selection(field_set, opts)
	if selection_err then
		return nil, selection_err
	end

	local data, err = client.request(string.format([[query CompassComponent($id: ID!) {
		compass {
			component(id: $id) {
				__typename
				... on CompassComponent {
%s
				}
				... on QueryError {
					identifier
					message
				}
			}
		}
	}]], selection), {
		id = normalized_id,
	}, {
		operation_name = "CompassComponent",
		experimental_apis = opts.experimental_apis,
		response_mode = opts.response_mode,
	})
	if err then
		return nil, err
	end

	if opts.response_mode == "envelope" then
		return data, nil
	end

	return extract_path(data, "compass.component"), nil
end

function compass.searchComponents(query, opts)
	opts = opts or {}

	local cloud_id, cloud_id_err = client.get_cloud_id()
	if cloud_id_err then
		return make_error_iterator(cloud_id_err)
	end

	local query_input, query_err = search_query_input(query, opts)
	if query_err then
		return make_error_iterator(query_err)
	end

	local field_set, field_err = validate_field_set(opts.field_set)
	if field_err then
		return make_error_iterator(field_err)
	end

	local selection, selection_err = component_selection(field_set, opts)
	if selection_err then
		return make_error_iterator(selection_err)
	end

	query_input.cloudId = cloud_id

	local iter, err = client.list(string.format([[query CompassSearchComponents($cloudId: String!, $query: CompassSearchComponentQuery) {
		compass {
			searchComponents(cloudId: $cloudId, query: $query) {
				__typename
				... on CompassSearchComponentConnection {
					pageInfo {
						hasNextPage
						endCursor
					}
					nodes {
						component {
%s
						}
					}
				}
				... on QueryError {
					identifier
					message
				}
			}
		}
	}]], selection), query_input, {
		kind = "cursor",
		connection_path = "compass.searchComponents",
		cursor_variable = "query.after",
		page_size_variable = "query.first",
		edges_path = "nodes",
		node_path = "component",
	}, {
		operation_name = "CompassSearchComponents",
		experimental_apis = opts.experimental_apis,
		limit = opts.limit,
		per_page = opts.per_page,
	})
	if err then
		return make_error_iterator(err)
	end

	return iter
end

function compass.componentLogs(component_id, opts)
	opts = opts or {}

	local normalized_id, id_err = normalize_scalar_id(component_id, "component_id")
	if id_err then
		return make_error_iterator(id_err)
	end

	local field_set, field_err = validate_field_set(opts.field_set)
	if field_err then
		return make_error_iterator(field_err)
	end

	local iter, err = client.list(string.format([[query CompassComponentLogs($id: ID!, $first: Int, $after: String) {
		compass {
			component(id: $id) {
				id
				logs(first: $first, after: $after) {
					pageInfo {
						hasNextPage
						endCursor
					}
					nodes {
%s
					}
				}
			}
		}
	}]], component_log_fields(field_set)), {
		id = normalized_id,
	}, {
		kind = "cursor",
		connection_path = "compass.component.logs",
		edges_path = "nodes",
		node_path = "",
	}, {
		operation_name = "CompassComponentLogs",
		experimental_apis = opts.experimental_apis,
		limit = opts.limit,
		per_page = opts.per_page,
	})
	if err then
		return make_error_iterator(err)
	end

	return iter
end
