-- {{SERVICE}} read-only integration tests
--
-- These tests run by default. Replace the starter call and assertions with
-- authenticated, non-mutating checks for this service. Cover authentication,
-- API wiring, response normalization, pagination, and representative read
-- operations. Do not create, modify, or delete remote resources here.
--
-- The initial NOT_IMPLEMENTED check lets an unmodified bootstrap pack report a
-- clear skip. Once the service is implemented, replace "example-id" with a
-- tightly scoped read fixture and remove this starter skip.

local result, err = {{SERVICE}}.resource.get("example-id")
if result == nil and type(err) == "table" and err.code == "NOT_IMPLEMENTED" then
  return {
    __munray_test_status = "SKIPPED",
    reason = "replace the starter read-only integration test after implementing the service",
  }
end

assert(result ~= nil, err and err.message or "read-only API operation failed")
assert(type(result) == "table", "read-only API operation must return a normalized table")

-- TODO: Assert the normalized fields expected by the public contract.
-- TODO: Exercise at least one paginated read operation without materializing
--       an unbounded result set.
