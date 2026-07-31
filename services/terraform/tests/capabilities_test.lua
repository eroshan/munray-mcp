-- Test terraform service capabilities

test.describe("Terraform Service - Namespace")

test.assert_not_nil(terraform, "terraform namespace should exist")
test.assert_eq(type(terraform.parse_plan), "function", "terraform.parse_plan should be a function")

test.describe("Terraform Service - Schema Discovery")

test.assert_not_nil(terraform.__schema, "terraform.__schema should exist")
test.assert_eq(terraform.__schema.namespace, "terraform", "namespace should be terraform")
test.assert_eq(terraform.__schema.service, "terraform", "service should be terraform")

test.assert_not_nil(terraform.__schema.functions, "terraform.__schema.functions should exist")
test.assert(#terraform.__schema.functions > 0, "terraform schema should have at least one function")

local schema, err = capabilities.schema("terraform")
test.assert_nil(err, "capabilities.schema(\"terraform\") should not error")
test.assert_not_nil(schema, "schema should not be nil")
test.assert_eq(schema.namespace, "terraform", "schema namespace should match")

test.summary()
