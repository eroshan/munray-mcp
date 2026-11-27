local namespace, directory, legacy_config = ...
assert(sys.mcp, "this service pack requires Munray's mcp-client feature")
assert(rawget(_G, namespace) == nil, "MCP pack namespace already exists: " .. namespace)

local config = legacy_config
if config == nil then
    local err
    config, err = sys.mcp.config(directory)
    if err then error(err.message) end
end
assert(type(config.tools) == "table", "MCP config.lua must define a tools table")

local catalog, catalog_err = sys.mcp.catalog(directory)
if catalog_err then error(catalog_err.message) end

local auth, auth_err = sys.mcp.auth(config.connection, catalog.integration)
if auth_err then error(auth_err.message) end

local service = {
    __schema = {
        namespace = namespace,
        service = namespace,
        summary = "Tools from an external MCP server",
        functions = {},
    },
}

local function wrap(remote_name)
    return function(args)
        return sys.mcp.tool_call(auth, remote_name, args)
    end
end

local names = {}
for name in pairs(catalog.tools) do
    names[#names + 1] = name
end
table.sort(names)

for _, remote_name in ipairs(names) do
    local tool = catalog.tools[remote_name]
    local policy = rawget(config.tools, remote_name)
    if policy ~= nil then
        assert(type(policy) == "table" and type(policy.enabled) == "boolean",
            "MCP policy requires a boolean enabled field for " .. remote_name)
        if policy.enabled then
            assert(policy.guarded == nil or type(policy.guarded) == "boolean",
                "MCP policy requires a boolean guarded field for " .. remote_name)
            service[tool.lua_name] = wrap(remote_name)
            table.insert(service.__schema.functions, {
                name = tool.lua_name,
                signature = "(args?)",
                description = tool.description,
                guarded = policy.guarded ~= false,
                input_schema = tool.input_schema,
                output_schema = tool.output_schema,
                params = { { name = "args", type = "table", optional = true } },
                returns_contract = "core.result",
                returns_typed = {
                    { name = "result", type = "table" },
                    { name = "err", type = "core.error|nil" },
                },
            })
        end
    end
end

_G[namespace] = service
