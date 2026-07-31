test.describe("Jira Service - Create Payload Normalization")

test.assert_eq(type(jira.issue._normalize_create_payload), "function", "create payload helper should exist")

local shorthand_body, shorthand_err = jira.issue._normalize_create_payload({
    project = { key = "TEST" },
    issuetype = { name = "Task" },
    summary = "simple create",
})

test.assert_not_nil(shorthand_body, "shorthand create payload should normalize")
test.assert_nil(shorthand_err, "shorthand create payload should not error")
test.assert_not_nil(shorthand_body.fields, "shorthand payload should be wrapped in fields")
test.assert_eq(shorthand_body.fields.project.key, "TEST", "shorthand payload should preserve project")
test.assert_eq(shorthand_body.fields.issuetype.name, "Task", "shorthand payload should preserve issuetype")
test.assert_eq(shorthand_body.fields.summary, "simple create", "shorthand payload should preserve summary")
test.assert_nil(shorthand_body.update, "shorthand payload should not inject update")

local full_body, full_err = jira.issue._normalize_create_payload({
    fields = {
        project = { key = "TEST" },
        issuetype = { name = "Task" },
        summary = "linked create",
    },
    update = {
        issuelinks = {
            {
                add = {
                    type = { name = "Blocks" },
                    outwardIssue = { key = "TEST-1" },
                }
            }
        }
    },
    properties = {
        {
            key = "example",
        }
    },
})

test.assert_not_nil(full_body, "native create payload should normalize")
test.assert_nil(full_err, "native create payload should not error")
test.assert_eq(full_body.fields.project.key, "TEST", "native payload should preserve fields.project")
test.assert_eq(full_body.fields.summary, "linked create", "native payload should preserve fields.summary")
test.assert_not_nil(full_body.update, "native payload should preserve update section")
test.assert_eq(full_body.update.issuelinks[1].add.type.name, "Blocks", "native payload should preserve issue link type")
test.assert_eq(full_body.update.issuelinks[1].add.outwardIssue.key, "TEST-1", "native payload should preserve outward issue key")
test.assert_not_nil(full_body.properties, "native payload should preserve properties")

local missing_fields_body, missing_fields_err = jira.issue._normalize_create_payload({
    update = {
        issuelinks = {}
    }
})

test.assert_nil(missing_fields_body, "native payload without fields should fail")
test.assert_not_nil(missing_fields_err, "native payload without fields should return error")
test.assert_eq(missing_fields_err.code, "MISSING_REQUIRED_FIELD", "native payload without fields should surface missing fields error")

local invalid_body, invalid_err = jira.issue._normalize_create_payload("not-a-table")
test.assert_nil(invalid_body, "non-table payload should fail")
test.assert_not_nil(invalid_err, "non-table payload should return error")
test.assert_eq(invalid_err.code, "VALIDATION_FAILED", "non-table payload should return VALIDATION_FAILED")

test.summary()
