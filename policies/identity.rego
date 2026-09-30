package main

import rego.v1

# 1. Deny IAM policies containing wildcard actions ('*')
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_iam_policy"
    doc := json.unmarshal(resource.change.after.policy)
    some statement in doc.Statement
    
    statement.Effect == "Allow"
    has_wildcard(statement.Action)

    msg := sprintf("SECURITY VIOLATION [%v]: IAM Policy allows unrestricted wildcard actions ('*'). Specify explicit actions.", [resource.address])
}

# Type-safe helpers: handles both single string and array representations
has_wildcard(action) if {
    is_string(action)
    action == "*"
}

has_wildcard(action) if {
    is_array(action)
    some a in action
    a == "*"
}

# 2. Deny IAM roles with MaxSessionDuration exceeding 1 hour (3600 seconds)
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_iam_role"
    
    duration := object.get(resource.change.after, "max_session_duration", 3600)
    duration > 3600

    msg := sprintf("GOVERNANCE VIOLATION [%v]: MaxSessionDuration is %v seconds. Non-human identities must not exceed 3600 seconds (1 hour).", [resource.address, duration])
}
