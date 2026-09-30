output "vpc_id" {
  value = module.network.vpc_id
}

output "isolated_subnet_ids" {
  value = module.network.isolated_subnet_ids
}

output "deployer_role_arn" {
  value = module.identity.role_arn
}

output "model_bucket_id" {
  value = module.data.bucket_id
}

output "kms_key_arn" {
  value = module.data.kms_key_arn
}

output "ecs_cluster_name" {
  value = module.compute.cluster_name
}

output "ecs_task_definition_arn" {
  value = module.compute.task_definition_arn
}

output "governance_event_bus_name" {
  value = module.circuit_breaker.event_bus_name
}

output "agent_queue_url" {
  value = module.circuit_breaker.invocation_queue_url
}

output "kill_switch_lambda_arn" {
  value = module.circuit_breaker.kill_switch_function_arn
}

output "ingress_task_endpoint" {
  value = module.ingress.api_endpoint
}

output "ingress_waf_arn" {
  value = module.ingress.waf_arn
}
