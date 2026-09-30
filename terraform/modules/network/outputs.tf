output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "isolated_subnet_ids" {
  value = aws_subnet.isolated[*].id
}

output "isolated_route_table_id" {
  value = aws_route_table.isolated.id
}

output "compute_security_group_id" {
  value = aws_security_group.compute_isolated.id
}
