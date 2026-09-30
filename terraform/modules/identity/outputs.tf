output "role_arn" {
  value = aws_iam_role.deployer.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}

output "permissions_boundary_arn" {
  value = aws_iam_policy.boundary.arn
}
