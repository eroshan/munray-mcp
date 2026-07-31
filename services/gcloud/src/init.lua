-- preload/gcloud/init.lua
-- Initialize gcloud namespace

gcloud = gcloud or {}
gcloud.project = gcloud.project or {}
gcloud.logs = gcloud.logs or {}
gcloud.bigquery = gcloud.bigquery or {}
gcloud.monitoring = gcloud.monitoring or {}
gcloud.monitoring.alert = gcloud.monitoring.alert or {}
gcloud.monitoring.policy = gcloud.monitoring.policy or {}
gcloud.monitoring.descriptor = gcloud.monitoring.descriptor or {}
gcloud.monitoring.series = gcloud.monitoring.series or {}

gcloud.__intro = [[
Use this service for Google Cloud operations.
Prefer narrow project scopes and structured outputs across BigQuery, Monitoring, Logs, and related services.
]]

gcloud.__allowed_cli_commands = { "bq", "gcloud" }

gcloud.__schema = {
	namespace = "gcloud",
	service = "gcloud",
	description = "Google Cloud CLI-backed utilities (service pack root).",
	functions = {},
	resources = { "gcloud.project", "gcloud.logs", "gcloud.bigquery", "gcloud.monitoring.alert", "gcloud.monitoring.policy", "gcloud.monitoring.descriptor", "gcloud.monitoring.series" },
}
