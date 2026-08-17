-- {{SERVICE}} service pack
--
-- This file is the only pack entrypoint. The loader runs it before the other
-- files in this pack's src/ directory. Create public namespace tables here;
-- add implementation files beside this one. Those files run in lexical order.
--
-- Pack code is trusted host code. Keep module loading side-effect free: do not
-- make network calls, resolve credentials, or run commands while this file is
-- loaded. Public functions must be stateless and take all request inputs
-- explicitly.

{{SERVICE}} = {
  resource = {},
}

{{SERVICE}}.__intro = [[
Use this service for <describe the integration>.
Prefer narrow scopes and structured outputs.
]]

-- Add a command name here before implementing a CLI-backed wrapper. The core
-- denies CLI use until it is listed. Keep this table absent for HTTP/GraphQL-
-- only packs.
-- {{SERVICE}}.__allowed_cli_commands = { "<binary>" }

-- Every public namespace needs schema metadata. The root advertises its child
-- namespaces; public functions are described where they are implemented.
{{SERVICE}}.__schema = {
  namespace = "{{SERVICE}}",
  service = "{{SERVICE}}",
  description = "<Describe this integration, required configuration, and scope.>",
  functions = {},
  resources = { "{{SERVICE}}.resource" },
}
