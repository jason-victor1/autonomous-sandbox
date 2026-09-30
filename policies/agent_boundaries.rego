package main

import rego.v1

# 1. Enforce that all SQS Queues have KMS Server-Side Encryption enabled
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_sqs_queue"
    
    not is_defined(resource.change, "kms_master_key_id")

    msg := sprintf("UNENCRYPTED QUEUE [%v]: SQS queues must specify a 'kms_master_key_id'.", [resource.address])
}

# 2. Enforce that non-DLQ SQS Queues have a redrive policy configured
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_sqs_queue"
    
    name := object.get(resource.change.after, "name", "")
    not contains(name, "dlq")
    
    not is_defined(resource.change, "redrive_policy")

    msg := sprintf("MISSING DLQ [%v]: Production queues must declare a 'redrive_policy' targeting a dead-letter queue.", [resource.address])
}

# 3. Agent Task Role must NEVER possess ecs:StopTask or iam:PutRolePolicy (Privilege Escalation Prevention)
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_iam_policy"
    
    name := object.get(resource.change.after, "name", "")
    contains(name, "task-runtime")
    
    doc := json.unmarshal(resource.change.after.policy)
    some statement in doc.Statement
    statement.Effect == "Allow"
    
    actions := get_actions(statement.Action)
    some act in actions
    act in ["ecs:StopTask", "iam:PutRolePolicy", "iam:AttachRolePolicy", "*"]

    msg := sprintf("PRIVILEGE ESCALATION VULNERABILITY [%v]: Agent runtime role is granted prohibited action '%v'.", [resource.address, act])
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Attribute is valid if explicitly known in 'after' OR computed in 'after_unknown'
is_defined(change, attribute) if {
    val := object.get(change.after, attribute, null)
    val != null
}

is_defined(change, attribute) if {
    object.get(change.after_unknown, attribute, false) == true
}

# Normalize string or array actions for uniform policy evaluation
get_actions(action) := [action] if is_string(action)
get_actions(action) := action if is_array(action)
