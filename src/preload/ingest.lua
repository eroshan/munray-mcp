-- preload/ingest.lua
-- luacheck: globals ingest
-- User-facing ingest namespace (ingest.*)

if type(_raw) ~= "table" or type(_raw.ingest) ~= "table" then
	return
end

ingest = {}

ingest.__schema = {
	namespace = "ingest",
	service = "core",
	description = "Read UTF-8 text previously uploaded into the current session via `munray-mcp ingest`.",
	examples = [[
-- Read text that was previously uploaded into this session:
-- some-command | munray-mcp ingest --server <server_id> --session <session_id>
local text, err = ingest.get("ing_0123456789abcdef0123456789abcdef")
if err then error(err.message) end
print(text)
]],
	functions = {
		{
			name = "get",
			path = "ingest.get",
			signature = "(token)",
			returns_contract = "core.result",
			mutating = false,
			description = "Read UTF-8 text for an ingest token previously stored in the current session.",
			params = {
				{ name = "token", type = "string", description = "Token returned by `munray-mcp ingest`" },
			},
			returns_typed = {
				{ name = "text", type = "string" },
				{ name = "err", type = "core.error|nil" },
			},
			examples = [[
local text, err = ingest.get("ing_0123456789abcdef0123456789abcdef")
if err then error(err.message) end
return text
]],
		},
	},
}

function ingest.get(token)
	return _raw.ingest.get(token)
end
