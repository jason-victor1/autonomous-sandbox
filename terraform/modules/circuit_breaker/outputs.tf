output "event_bus_arn" {
  value = aws_cloudwatch_event_bus.sandbox_bus.arn
}

output "event_bus_name" {
  value = aws_cloudwatch_event_bus.sandbox_bus.name
}

output "kill_switch_function_arn" {
  value = aws_lambda_function.kill_switch.arn
}

output "invocation_queue_url" {
  value = aws_sqs_queue.agent_tasks.url
}

output "invocation_queue_arn" {
  value = aws_sqs_queue.agent_tasks.arn
}
