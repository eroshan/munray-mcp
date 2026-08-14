-- User-space durable key/value storage. Core-owned persistence (snippets,
-- metrics, and registry state) is intentionally not exposed through this API.
if type(_raw) ~= "table" or type(_raw.kv) ~= "table" then return end

kv = {}
function kv.put(namespace, key, value) return _raw.kv.put(namespace, key, value) end
function kv.get(namespace, key) return _raw.kv.get(namespace, key) end
function kv.delete(namespace, key) return _raw.kv.delete(namespace, key) end
function kv.keys(namespace) return _raw.kv.keys(namespace) end
function kv.len(namespace) return _raw.kv.len(namespace) end
function kv.clear(namespace) return _raw.kv.clear(namespace) end

local function descriptor(name, mutating, signature, description)
  return {name=name,path="kv."..name,mutating=mutating,signature=signature,returns_contract="core.result",description=description,returns_typed={{name="result",type="any"},{name="err",type="core.error|nil"}}}
end
kv.__schema = { namespace = "kv", service = "core", functions = {
  descriptor("put", true, "(namespace, key, value)", "Store a value by namespace and key"),
  descriptor("get", false, "(namespace, key)", "Get a value by namespace and key"),
  descriptor("delete", true, "(namespace, key)", "Delete a value by namespace and key"),
  descriptor("keys", false, "(namespace)", "List keys in a namespace"),
  descriptor("len", false, "(namespace)", "Count entries in a namespace"),
  descriptor("clear", true, "(namespace)", "Clear a namespace"),
}}
