-- User-space durable key/value storage. Core-owned persistence (snippets,
-- metrics, and registry state) is intentionally not exposed through this API.
if type(sys) ~= "table" or type(sys.kv) ~= "table" then return end

kv = {}
function kv.put(namespace, key, value, opts) return sys.kv.put(namespace, key, value, opts) end
function kv.get(namespace, key) return sys.kv.get(namespace, key) end
function kv.delete(namespace, key) return sys.kv.delete(namespace, key) end
function kv.keys(namespace) return sys.kv.keys(namespace) end
function kv.len(namespace) return sys.kv.len(namespace) end
function kv.clear(namespace) return sys.kv.clear(namespace) end

local function descriptor(name, readonly, signature, description)
  return {name=name,path="kv."..name,readonly=readonly,signature=signature,returns_contract="core.result",description=description,returns_typed={{name="result",type="any"},{name="err",type="core.error|nil"}}}
end
kv.__schema = { namespace = "kv", service = "core", functions = {
  descriptor("put", false, "(namespace, key, value)", "Store a value by namespace and key"),
  descriptor("get", true, "(namespace, key)", "Get a value by namespace and key"),
  descriptor("delete", false, "(namespace, key)", "Delete a value by namespace and key"),
  descriptor("keys", true, "(namespace)", "List keys in a namespace"),
  descriptor("len", true, "(namespace)", "Count entries in a namespace"),
  descriptor("clear", false, "(namespace)", "Clear a namespace"),
}}
