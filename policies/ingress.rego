package main

import rego.v1

# 1. Enforce that API Gateway Stages must have CloudWatch access logging configured
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_api_gateway_stage"

    logs := object.get(resource.change.after, "access_log_settings", [])
    count(logs) == 0

    msg := sprintf("UNAUDITED INGRESS [%v]: API Gateway stage must configure 'access_log_settings' to capture caller IP and telemetry.", [resource.address])
}

# 2. Enforce that API Gateway Stages must enable X-Ray tracing
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_api_gateway_stage"

    tracing := object.get(resource.change.after, "xray_tracing_enabled", false)
    tracing != true

    msg := sprintf("OBSERVABILITY GAP [%v]: API Gateway stage must enable 'xray_tracing_enabled' for distributed incident investigation.", [resource.address])
}

# 3. Enforce that a WAF Web ACL association is defined for ingress
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_wafv2_web_acl"

    name := object.get(resource.change.after, "name", "")
    contains(name, "ingress")

    not has_waf_association

    msg := sprintf("EXPOSED INGRESS [%v]: Public-facing WAF Web ACL declared without corresponding 'aws_wafv2_web_acl_association'.", [resource.address])
}

# Helper: Verify an association resource exists in the execution plan
has_waf_association if {
    some resource in input.resource_changes
    resource.type == "aws_wafv2_web_acl_association"
}
