-- Terraform Examples
-- This focuses on parsing textual plan output into structured data.

-- plan_output should be the textual output from `terraform plan` or terragrunt
local result, err = terraform.parse_plan(plan_output)
if err then error(err) end

print("add:", result.summary.add, "change:", result.summary.change, "destroy:", result.summary.destroy)
if result.has_replacements then
	print("Plan requires replacements")
end
