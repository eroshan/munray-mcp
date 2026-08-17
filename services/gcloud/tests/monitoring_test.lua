test.describe("GCloud Service - Monitoring Namespace")

local function find_fn(schema, name)
	for _, fn in ipairs(schema.functions or {}) do
		if fn.name == name then
			return fn
		end
	end
	return nil
end

test.assert_not_nil(gcloud.monitoring, "gcloud.monitoring namespace should exist")
test.assert_not_nil(gcloud.monitoring.alert, "gcloud.monitoring.alert namespace should exist")
test.assert_not_nil(gcloud.monitoring.policy, "gcloud.monitoring.policy namespace should exist")
test.assert_not_nil(gcloud.monitoring.descriptor, "gcloud.monitoring.descriptor namespace should exist")
test.assert_not_nil(gcloud.monitoring.series, "gcloud.monitoring.series namespace should exist")
test.assert_eq(type(gcloud.monitoring.alert.list), "function", "gcloud.monitoring.alert.list should be a function")
test.assert_eq(type(gcloud.monitoring.alert.describe), "function", "gcloud.monitoring.alert.describe should be a function")
test.assert_eq(type(gcloud.monitoring.policy.list), "function", "gcloud.monitoring.policy.list should be a function")
test.assert_eq(type(gcloud.monitoring.policy.describe), "function", "gcloud.monitoring.policy.describe should be a function")
test.assert_eq(type(gcloud.monitoring.descriptor.list), "function", "gcloud.monitoring.descriptor.list should be a function")
test.assert_eq(type(gcloud.monitoring.series.list), "function", "gcloud.monitoring.series.list should be a function")

local alert_schema, alert_err = schema("gcloud.monitoring.alert")
test.assert_nil(alert_err, "schema should not error for gcloud.monitoring.alert")
test.assert_not_nil(alert_schema, "alert schema should not be nil")
test.assert_eq(alert_schema.namespace, "gcloud.monitoring.alert", "alert schema namespace should match")

local alert_list_fn = find_fn(alert_schema, "list")
test.assert_not_nil(alert_list_fn, "alert.list function should exist in schema")
test.assert_eq(alert_list_fn.returns_contract, "core.iter", "alert.list should return iterator contract")
test.assert_eq(alert_list_fn.yields, "Alert", "alert.list should yield Alert")

local alert_describe_fn = find_fn(alert_schema, "describe")
test.assert_not_nil(alert_describe_fn, "alert.describe function should exist in schema")
test.assert_eq(alert_describe_fn.returns_contract, "core.result", "alert.describe should follow core.result contract")

local policy_schema, policy_err = schema("gcloud.monitoring.policy")
test.assert_nil(policy_err, "schema should not error for gcloud.monitoring.policy")
test.assert_not_nil(policy_schema, "policy schema should not be nil")
test.assert_eq(policy_schema.namespace, "gcloud.monitoring.policy", "policy schema namespace should match")

local policy_list_fn = find_fn(policy_schema, "list")
test.assert_not_nil(policy_list_fn, "policy.list function should exist in schema")
test.assert_eq(policy_list_fn.returns_contract, "core.iter", "policy.list should return iterator contract")
test.assert_eq(policy_list_fn.yields, "AlertPolicy", "policy.list should yield AlertPolicy")

local policy_describe_fn = find_fn(policy_schema, "describe")
test.assert_not_nil(policy_describe_fn, "policy.describe function should exist in schema")
test.assert_eq(policy_describe_fn.returns_contract, "core.result", "policy.describe should follow core.result contract")

local descriptor_schema, descriptor_err = schema("gcloud.monitoring.descriptor")
test.assert_nil(descriptor_err, "schema should not error for gcloud.monitoring.descriptor")
test.assert_not_nil(descriptor_schema, "descriptor schema should not be nil")
test.assert_eq(descriptor_schema.namespace, "gcloud.monitoring.descriptor", "descriptor schema namespace should match")

local descriptor_fn = find_fn(descriptor_schema, "list")
test.assert_not_nil(descriptor_fn, "descriptor.list function should exist in schema")
test.assert_eq(descriptor_fn.returns_contract, "core.iter", "descriptor.list should return iterator contract")
test.assert_eq(descriptor_fn.yields, "MetricDescriptor", "descriptor.list should yield MetricDescriptor")

local series_schema, series_err = schema("gcloud.monitoring.series")
test.assert_nil(series_err, "schema should not error for gcloud.monitoring.series")
test.assert_not_nil(series_schema, "series schema should not be nil")
test.assert_eq(series_schema.namespace, "gcloud.monitoring.series", "series schema namespace should match")

local series_fn = find_fn(series_schema, "list")
test.assert_not_nil(series_fn, "series.list function should exist in schema")
test.assert_eq(series_fn.returns_contract, "core.iter", "series.list should return iterator contract")
test.assert_eq(series_fn.yields, "TimeSeries", "series.list should yield TimeSeries")

test.describe("GCloud Service - Monitoring Validation")

local iter1, err1 = gcloud.monitoring.series.list("test-project-123", {})
test.assert_nil(iter1, "series.list should fail when filter missing")
test.assert_not_nil(err1, "series.list should return error when filter missing")
test.assert_eq(err1.code, "MISSING_REQUIRED_FIELD", "series.list should validate required filter")

local iter2, err2 = gcloud.monitoring.series.list("test-project-123", {
	filter = 'metric.type="compute.googleapis.com/instance/cpu/utilization"',
	interval = { start_time = "2026-03-23T10:00:00Z" },
})
test.assert_nil(iter2, "series.list should fail when end_time missing")
test.assert_not_nil(err2, "series.list should return error when end_time missing")
test.assert_eq(err2.code, "INVALID_FIELD_VALUE", "series.list should validate interval.end_time")

local iter3, err3 = gcloud.monitoring.descriptor.list("bad", {})
test.assert_nil(iter3, "descriptor.list should fail when project invalid")
test.assert_not_nil(err3, "descriptor.list should return error when project invalid")
test.assert_eq(err3.code, "INVALID_FIELD_VALUE", "descriptor.list should validate project")

local iter4, err4 = gcloud.monitoring.alert.list("test-project-123", { filter = 123 })
test.assert_nil(iter4, "alert.list should fail when filter is not a string")
test.assert_not_nil(err4, "alert.list should return error when filter is not a string")
test.assert_eq(err4.code, "INVALID_FIELD_VALUE", "alert.list should validate filter")

local iter5, err5 = gcloud.monitoring.policy.list("bad", {})
test.assert_nil(iter5, "policy.list should fail when project invalid")
test.assert_not_nil(err5, "policy.list should return error when project invalid")
test.assert_eq(err5.code, "INVALID_FIELD_VALUE", "policy.list should validate project")

local alert_info, alert_info_err = gcloud.monitoring.alert.describe("0.o85p1apfrn44", {})
test.assert_nil(alert_info, "alert.describe should fail when short alert ID lacks project")
test.assert_not_nil(alert_info_err, "alert.describe should return error when short alert ID lacks project")
test.assert_eq(alert_info_err.code, "MISSING_REQUIRED_FIELD", "alert.describe should require opts.project for short IDs")

local policy_info, policy_info_err = gcloud.monitoring.policy.describe("17443123117273840437", {})
test.assert_nil(policy_info, "policy.describe should fail when short policy ID lacks project")
test.assert_not_nil(policy_info_err, "policy.describe should return error when short policy ID lacks project")
test.assert_eq(policy_info_err.code, "MISSING_REQUIRED_FIELD", "policy.describe should require opts.project for short IDs")

local policy_info2, policy_info_err2 = gcloud.monitoring.policy.describe("projects/test-project-123/alertPolicies/17443123117273840437", "bad")
test.assert_nil(policy_info2, "policy.describe should fail when opts is not a table")
test.assert_not_nil(policy_info_err2, "policy.describe should return error when opts is not a table")
test.assert_eq(policy_info_err2.code, "INVALID_OPTIONS", "policy.describe should validate opts type")

test.summary()
