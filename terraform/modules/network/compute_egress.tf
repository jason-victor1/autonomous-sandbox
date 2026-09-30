resource "aws_vpc_security_group_egress_rule" "compute_egress_s3" {
  security_group_id = aws_security_group.compute_isolated.id
  description       = "Allow HTTPS to S3 gateway endpoint for ECR layers"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  prefix_list_id    = data.aws_prefix_list.s3.id
}

resource "aws_vpc_security_group_egress_rule" "compute_egress_dns_udp" {
  security_group_id = aws_security_group.compute_isolated.id
  description       = "Allow Route 53 DNS UDP resolver"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "compute_egress_dns_tcp" {
  security_group_id = aws_security_group.compute_isolated.id
  description       = "Allow Route 53 DNS TCP resolver"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.vpc_cidr
}
