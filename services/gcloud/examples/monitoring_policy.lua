-- GCloud Monitoring alerting policy namespace example

local PROJECT = "YOUR_GCP_PROJECT"

local iter = gcloud.monitoring.policy.list(PROJECT, {
	filter = "NOT display_name.empty",
})

local policies, err = helpers.collect(iter, { limit = 5 })
if err then error(err.message or tostring(err)) end

if #policies == 0 then
	return { count = 0, note = "no matching policies" }
end

local policy, describe_err = gcloud.monitoring.policy.describe(policies[1].name)
if describe_err then error(describe_err.message or tostring(describe_err)) end

return {
	count = #policies,
	first = policy,
}
