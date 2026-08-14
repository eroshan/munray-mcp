test.describe("Compass Service - Capabilities")

test.assert_not_nil(compass, "compass namespace should exist")
test.assert_eq(type(compass.ready), "function", "compass.ready should be a function")
test.assert_eq(type(compass.components), "function", "compass.components should be a function")
test.assert_eq(type(compass.component), "function", "compass.component should be a function")
test.assert_eq(type(compass.searchComponents), "function", "compass.searchComponents should be a function")
test.assert_eq(type(compass.componentLogs), "function", "compass.componentLogs should be a function")

local schema = capabilities.schema("compass")
test.assert_not_nil(schema, "compass schema should be discoverable")
test.assert_eq(schema.namespace, "compass", "compass schema namespace should match")
test.assert_eq(schema.service, "compass", "compass schema service should match")
test.assert_not_nil(schema.functions, "compass schema should include functions")

local seen = {}
for _, fn in ipairs(schema.functions) do
	seen[fn.name] = true
	if fn.name == "searchComponents" or fn.name == "componentLogs" then
		test.assert_eq(fn.returns_contract, "core.iter", fn.name .. " should be an iterator contract")
		test.assert_eq(fn.readonly, true, fn.name .. " should not be guarded")
	else
		test.assert_eq(fn.returns_contract, "core.result", fn.name .. " should be a result contract")
		test.assert_eq(fn.readonly, true, fn.name .. " should not be guarded")
	end
end

test.assert(seen.ready, "schema should include ready")
test.assert(seen.components, "schema should include components")
test.assert(seen.component, "schema should include component")
test.assert(seen.searchComponents, "schema should include searchComponents")
test.assert(seen.componentLogs, "schema should include componentLogs")
