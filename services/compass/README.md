# Compass service pack

Read-only Atlassian Compass service pack built on `_raw.graphql.*`.

## Required environment

- `COMPASS_BASE_URL` or `JIRA_BASE_URL` (for example `https://example.atlassian.net`)
- `COMPASS_EMAIL` or `JIRA_EMAIL`
- `COMPASS_API_TOKEN` or `JIRA_API_TOKEN`

## Public functions

- `compass.ready()`
- `compass.components(ids, opts?)`
- `compass.component(id, opts?)`
- `compass.searchComponents(query, opts?)`
- `compass.componentLogs(component_id, opts?)`

## Component options

`compass.component(id, opts?)` supports:

- `field_set`: `minimal`, `default`, `full`
- `include_custom_fields = true`: include Compass custom fields in the response

Example:

```lua
compass.component(component_id, {
  include_custom_fields = true,
})
```
