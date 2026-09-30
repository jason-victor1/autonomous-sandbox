package main

import rego.v1

# 1. Deny S3 buckets configured with default AES256 or unencrypted (enforce KMS CMK)
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_s3_bucket_server_side_encryption_configuration"
    
    some r in resource.change.after.rule
    some apply in r.apply_server_side_encryption_by_default
    apply.sse_algorithm != "aws:kms"

    msg := sprintf("DATA PERIMETER BREACH [%v]: S3 SSE algorithm must be 'aws:kms'. Default 'AES256' is rejected.", [resource.address])
}

# 2. Deny S3 bucket without all Public Access Block containment flags enabled
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_s3_bucket_public_access_block"
    
    not all_blocks_enabled(resource.change.after)

    msg := sprintf("EXPOSURE RISK [%v]: S3 Public Access Block must set all four containment flags to true.", [resource.address])
}

# Helper: All four containment flags must evaluate to true
all_blocks_enabled(block) if {
    block.block_public_acls == true
    block.block_public_policy == true
    block.ignore_public_acls == true
    block.restrict_public_buckets == true
}

# 3. Deny ECS Tasks where Execution Role and Task Role are identical
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_ecs_task_definition"
    
    exec_role := object.get(resource.change.after, "execution_role_arn", null)
    task_role := object.get(resource.change.after, "task_role_arn", null)
    exec_role != null
    task_role != null
    exec_role == task_role

    msg := sprintf("PRIVILEGE OVERLAP [%v]: ECS Task Execution Role and Task Role must be decoupled.", [resource.address])
}

# 4. Deny ECS Containers that do not enforce a read-only root filesystem
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_ecs_task_definition"
    
    definitions := json.unmarshal(resource.change.after.container_definitions)
    some container in definitions
    container.readonlyRootFilesystem != true

    msg := sprintf("RUNTIME COMPROMISE RISK [%v]: Container '%v' must have readonlyRootFilesystem set to true.", [resource.address, container.name])
}
