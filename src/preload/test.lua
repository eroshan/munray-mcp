-- test.lua - Simple test framework for Lua services
-- Provides assert helpers and test result tracking

test = {}

local passed = 0
local failed = 0
local current_test = nil
local failure_messages = {}

-- Start a new test
function test.describe(name)
	current_test = name
	print(string.format("\n=== %s ===", name))
end

-- Assert that condition is true
function test.assert(condition, message)
	if condition then
		passed = passed + 1
		print(string.format("  ✓ %s", message or "assertion passed"))
	else
		failed = failed + 1
		local failure_message = message or "assertion failed"
		print(string.format("  ✗ %s", failure_message))
		if current_test then
			print(string.format("    in test: %s", current_test))
			failure_message = current_test .. ": " .. failure_message
		end
		table.insert(failure_messages, failure_message)
	end
end

-- Assert equality
function test.assert_eq(actual, expected, message)
	local msg = message or string.format("expected %s, got %s", tostring(expected), tostring(actual))
	test.assert(actual == expected, msg)
end

-- Assert not nil
function test.assert_not_nil(value, message)
	local msg = message or string.format("expected non-nil value, got nil")
	test.assert(value ~= nil, msg)
end

-- Assert nil
function test.assert_nil(value, message)
	local msg = message or string.format("expected nil, got %s", tostring(value))
	test.assert(value == nil, msg)
end

-- Assert error occurred
function test.assert_error(fn, message)
	local success = pcall(fn)
	local msg = message or "expected error to be thrown"
	test.assert(not success, msg)
end

-- Assert no error
function test.assert_no_error(fn, message)
	local success, err = pcall(fn)
	local msg = message or string.format("expected no error, got: %s", tostring(err))
	test.assert(success, msg)
end

-- Print test summary
function test.summary()
	print("\n" .. string.rep("=", 60))
	print(string.format("Tests: %d passed, %d failed, %d total",
		passed, failed, passed + failed))
	print(string.rep("=", 60))

	if failed > 0 then
		-- Let the Rust service-test runner report this file as failed and continue
		-- with the remaining test files instead of terminating the whole process.
		error("test assertions failed: " .. table.concat(failure_messages, "; "), 0)
	end
end

-- Reset counters (useful for running multiple test files)
function test.reset()
	passed = 0
	failed = 0
	current_test = nil
	failure_messages = {}
end
