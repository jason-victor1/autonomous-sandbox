package main

import rego.v1

# 1. Deny any Security Group Ingress open to 0.0.0.0/0
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_vpc_security_group_ingress_rule"
    
    resource.change.after.cidr_ipv4 == "0.0.0.0/0"
    
    msg := sprintf("NETWORK PERIMETER VIOLATION [%v]: Direct 0.0.0.0/0 ingress detected. Use private subnet routing or peer security groups.", [resource.address])
}

# 2. Deny any Route Table tagged 'isolated' from having an Internet Gateway route
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_route_table"
    
    tags := object.get(resource.change.after, "tags", {})
    tags.Tier == "isolated"

    routes := object.get(resource.change.after, "route", [])
    some r in routes
    gw := object.get(r, "gateway_id", "")
    gw != null
    gw != ""
    startswith(gw, "igw")

    msg := sprintf("ISOLATION COMPROMISED [%v]: Route table tagged 'isolated' directs traffic to an Internet Gateway.", [resource.address])
}

# 3. Ensure subnets marked 'isolated' do NOT map public IPs on launch
deny contains msg if {
    some resource in input.resource_changes
    resource.type == "aws_subnet"
    
    tags := object.get(resource.change.after, "tags", {})
    tags.Tier == "isolated"
    
    resource.change.after.map_public_ip_on_launch == true

    msg := sprintf("AIRGAP VIOLATION [%v]: Subnet in isolated AI tier has map_public_ip_on_launch set to true.", [resource.address])
}
