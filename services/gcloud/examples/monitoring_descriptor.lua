-- GCloud Monitoring metric descriptor examples

local PROJECT = "YOUR_GCP_PROJECT"

local iter = gcloud.monitoring.descriptor.list(PROJECT, {
	filter = 'metric.type = starts_with("compute.googleapis.com")',
	limit = 5,
})

local descriptors, err = helpers.collect(iter, { limit = 5 })
if err then error(err.message or tostring(err)) end

return {
	count = #descriptors,
	first = descriptors[1] and descriptors[1][1],
}
