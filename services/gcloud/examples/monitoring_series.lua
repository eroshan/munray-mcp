-- GCloud Monitoring time series examples
-- Practical patterns for cumulative, delta, and gauge metrics.

local PROJECT = "YOUR_GCP_PROJECT"

local function point_number(point)
	local value = (point and point.value) or {}
	if value.doubleValue ~= nil then return tonumber(value.doubleValue), "doubleValue" end
	if value.int64Value ~= nil then return tonumber(value.int64Value), "int64Value" end
	if value.distributionValue ~= nil then return nil, "distributionValue" end
	return nil, "unknown"
end

-- Example 1: Kubernetes CPU usage (CUMULATIVE metric) → ALIGN_RATE
local cpu_iter = gcloud.monitoring.series.list(PROJECT, {
	filter = 'metric.type="kubernetes.io/container/cpu/core_usage_time" AND resource.labels.namespace_name="default"',
	interval = {
		start_time = "2026-03-23T10:00:00Z",
		end_time = "2026-03-23T11:00:00Z",
	},
	view = "FULL",
	aggregation = {
		alignment_period = "60s",
		per_series_aligner = "ALIGN_RATE",
	},
	limit = 5,
})
local cpu_series, cpu_err = helpers.collect(cpu_iter, { limit = 5 })
if cpu_err then error(cpu_err.message or tostring(cpu_err)) end

-- Example 2: Gauge metric → ALIGN_MEAN
local mem_iter = gcloud.monitoring.series.list(PROJECT, {
	filter = 'metric.type="kubernetes.io/container/memory/used_bytes" AND resource.labels.namespace_name="default"',
	interval = {
		start_time = "2026-03-23T10:00:00Z",
		end_time = "2026-03-23T11:00:00Z",
	},
	view = "FULL",
	aggregation = {
		alignment_period = "60s",
		per_series_aligner = "ALIGN_MEAN",
	},
	limit = 5,
})
local mem_series, mem_err = helpers.collect(mem_iter, { limit = 5 })
if mem_err then error(mem_err.message or tostring(mem_err)) end

-- Example 3: Pub/Sub event count (counter-ish / integer points) → ALIGN_SUM
local pubsub_iter = gcloud.monitoring.series.list(PROJECT, {
	filter = 'metric.type="pubsub.googleapis.com/topic/send_message_operation_count"',
	interval = {
		start_time = "2026-03-23T10:00:00Z",
		end_time = "2026-03-23T11:00:00Z",
	},
	view = "FULL",
	aggregation = {
		alignment_period = "60s",
		per_series_aligner = "ALIGN_SUM",
	},
	limit = 5,
})
local pubsub_series, pubsub_err = helpers.collect(pubsub_iter, { limit = 5 })
if pubsub_err then error(pubsub_err.message or tostring(pubsub_err)) end

-- Safe value extraction from either doubleValue or int64Value.
local first_point = ((((pubsub_series[1] or {}).points) or {})[1])
local value, kind = point_number(first_point)

return {
	cpu_count = #cpu_series,
	memory_count = #mem_series,
	pubsub_count = #pubsub_series,
	first_pubsub_value = value,
	first_pubsub_value_kind = kind,
}
