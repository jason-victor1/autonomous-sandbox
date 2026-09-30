package main

import rego.v1

# Deny any standalone egress rule that allows egress to 0.0.0.0/0
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_vpc_security_group_egress_rule"
    resource.change.actions[_] in ["create", "update"]

    cidr := resource.change.after.cidr_ipv4
    cidr == "0.0.0.0/0"

    msg := sprintf(
        "CRITICAL: Egress rule '%v' authorizes egress to '0.0.0.0/0'. All agent egress must terminate strictly within internal VPC endpoints (10.0.0.0/16).",
        [resource.address]
    )
}
