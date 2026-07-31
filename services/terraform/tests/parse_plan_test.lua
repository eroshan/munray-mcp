test.describe("Terraform parse_plan - Wrapper Summary Precedence")

local esc = string.char(27)

local log = table.concat({
	esc .. "[0mTerraform is going to make changes" .. esc .. "[0K",
	"Resources to create: 213",
	"Resources to update (9 unchanged): 9",
	"Resources to destroy: 0",
	"",
	"# module.foo.google_service_account.bar will be created",
	"# module.foo.google_service_account.baz will be updated in-place",
	"# module.foo.google_service_account.old will be destroyed",
	"# module.foo.google_service_account.rep must be replaced",
	"",
	"Warning: Deprecated setting foo",
	"Warning: Deprecated setting foo",
	"Warning: Permanently added 'example.com' (ECDSA) to the list of known hosts.",
	"",
	"Error: Failed to create resource",
	"  with module.foo.google_service_account.bar,",
	"  on main.tf line 12, in resource \"google_service_account\" \"bar\":",
	"  12: name = \"x\"",
	"",
	"Plan: 1 to add, 0 to change, 0 to destroy.",
	"Plan: 222 to add, 9 to change, 0 to destroy.",
}, "\r\n")

local result, err = terraform.parse_plan(log)

test.assert_nil(err, "parse_plan should not error")
test.assert_not_nil(result, "result should not be nil")

-- Wrapper summary is authoritative and should win even if Plan: exists

test.assert_eq(result.summary.add, 213, "wrapper add should be authoritative")
test.assert_eq(result.summary.change, 9, "wrapper change should be authoritative")
test.assert_eq(result.summary.destroy, 0, "wrapper destroy should be authoritative")

-- Still retain Plan: lines for drill-down

test.assert_not_nil(result.module_plans, "module_plans should exist")
test.assert_eq(#result.module_plans, 2, "should capture both Plan: lines")
test.assert_eq(result.module_plans[2].add, 222, "plan_last add should match last Plan line")
test.assert_eq(result.module_plans[2].change, 9, "plan_last change should match last Plan line")

-- Surface mismatch between wrapper and Plan:

test.assert_not_nil(result.summary_sources, "summary_sources should exist")
test.assert_not_nil(result.summary_sources.wrapper, "summary_sources.wrapper should exist")
test.assert_not_nil(result.summary_sources.plan_last, "summary_sources.plan_last should exist")
test.assert_eq(result.summary_sources.wrapper.add, 213, "wrapper source should match")
test.assert_eq(result.summary_sources.plan_last.add, 222, "plan_last source should match")
test.assert_eq(result.summary_inconsistent, true, "summary_inconsistent should be true on mismatch")

-- Module address parsing should strip module.* prefixes

test.assert_eq(#result.resources_to_add, 1, "should parse 1 resource to add")
test.assert_eq(result.resources_to_add[1].type, "google_service_account", "type should be resource type")
test.assert_eq(result.resources_to_add[1].name, "bar", "name should be resource name")

test.assert_eq(#result.resources_to_change, 1, "should parse 1 resource to change")
test.assert_eq(result.resources_to_change[1].type, "google_service_account", "change type should be resource type")
test.assert_eq(result.resources_to_change[1].name, "baz", "change name should be resource name")

test.assert_eq(#result.resources_to_destroy, 1, "should parse 1 resource to destroy")
test.assert_eq(result.resources_to_destroy[1].type, "google_service_account", "destroy type should be resource type")
test.assert_eq(result.resources_to_destroy[1].name, "old", "destroy name should be resource name")

-- Replacements should be detected from clean log

test.assert_eq(result.has_replacements, true, "has_replacements should be true")

-- Warnings should be deduped and filtered

test.assert_eq(#result.warnings, 1, "should de-dupe warnings and filter known-host noise")
test.assert(result.warnings[1]:match("Deprecated setting"), "warning should include content")

-- Errors should include context lines, not just the header

test.assert(#result.errors >= 1, "should capture at least one error")
test.assert(result.errors[1]:match("with module%.foo%.google_service_account%.bar"), "error should include context lines")

test.summary()

test.describe("Terraform parse_plan - Edge Cases & Fixes")

-- Test 1: Wrapper format without parenthetical
local log1 = table.concat({
	"Resources to create: 5",
	"Resources to update: 3",
	"Resources to destroy: 1",
	"Plan: 5 to add, 3 to change, 1 to destroy."
}, "\n")

local result1, err1 = terraform.parse_plan(log1)
test.assert_nil(err1)
test.assert_eq(result1.summary.change, 3, "should parse update count without parenthetical")

-- Test 2: Data source type/name parsing
local log2 = table.concat({
	"# data.google_compute_network.vpc will be created",
	"# module.networking.data.google_project.proj will be updated in-place",
	"# google_storage_bucket.my_bucket will be destroyed",
	"Plan: 1 to add, 1 to change, 1 to destroy."
}, "\n")

local result2, err2 = terraform.parse_plan(log2)
test.assert_nil(err2)
test.assert_eq(result2.resources_to_add[1].type, "google_compute_network", "data source type should be resource type")
test.assert_eq(result2.resources_to_add[1].name, "vpc", "data source name should be resource name")
test.assert_eq(result2.resources_to_change[1].type, "google_project", "module data source should parse correctly")
test.assert_eq(result2.resources_to_change[1].name, "proj", "module data source name should be correct")
test.assert_eq(result2.resources_to_destroy[1].type, "google_storage_bucket", "regular resource should still work")

-- Test 3: Error context capture (8 lines)
local log3 = table.concat({
	"Error: Failed to create resource",
	"  line 1",
	"  line 2",
	"  line 3",
	"  line 4",
	"  line 5",
	"  line 6",
	"  line 7",
	"  line 8",
	"  line 9 should not be captured",
}, "\n")

local result3, err3 = terraform.parse_plan(log3)
test.assert_nil(err3)
test.assert(result3.errors[1]:match("line 8"), "should capture up to 8 context lines")
test.assert(not result3.errors[1]:match("line 9"), "should not capture beyond 8 lines")

test.summary()
