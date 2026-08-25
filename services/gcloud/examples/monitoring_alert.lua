-- GCloud Monitoring alert namespace example

local PROJECT = "YOUR_GCP_PROJECT"

local iter = gcloud.monitoring.alert.list(PROJECT, {
	filter = "state='OPEN'",
})

local alerts, err = helpers.collect(iter, { limit = 5 })
if err then error(err.message or tostring(err)) end

if #alerts == 0 then
	return { count = 0, note = "no matching alerts" }
end

local alert, describe_err = gcloud.monitoring.alert.describe(alerts[1].name)
if describe_err then error(describe_err.message or tostring(describe_err)) end

return {
	count = #alerts,
	first = alert,
}
