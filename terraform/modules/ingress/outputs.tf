output "api_endpoint" {
  value = "${aws_api_gateway_stage.live.invoke_url}/tasks"
}

output "waf_arn" {
  value = aws_wafv2_web_acl.ingress_waf.arn
}

output "api_gateway_stage_arn" {
  value = aws_api_gateway_stage.live.arn
}
