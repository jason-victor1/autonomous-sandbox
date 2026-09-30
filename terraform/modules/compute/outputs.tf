output "cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "cluster_id" {
  value = aws_ecs_cluster.main.id
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.agent_worker.arn
}

output "task_execution_role_arn" {
  value = aws_iam_role.task_execution_role.arn
}

output "task_role_arn" {
  value = aws_iam_role.task_role.arn
}

output "task_role_name" {
  description = "Name of the ECS task runtime role"
  value       = aws_iam_role.task_role.name
}
