data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Decoupled SQS Invocation Queue with Dead-Letter Containment
# -----------------------------------------------------------------------------

# 1. Dead-Letter Queue
resource "aws_sqs_queue" "dlq" {
  #checkov:skip=CKV_AWS_27: "Dead letter queue does not require its own redrive policy"
  name                      = "agent-invocation-dlq-${var.environment}.fifo"
  fifo_queue                = true
  message_retention_seconds = 1209600 # 14 days
  kms_master_key_id         = var.kms_key_arn

  tags = {
    Name = "agent-invocation-dlq"
  }
}

# 2. Main FIFO Queue for tool and agent triggers
resource "aws_sqs_queue" "agent_tasks" {
  name                       = "agent-invocation-queue-${var.environment}.fifo"
  fifo_queue                 = true
  content_based_deduplication = true
  kms_master_key_id          = var.kms_key_arn
  visibility_timeout_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "agent-invocation-queue"
  }
}

# -----------------------------------------------------------------------------
# EventBridge Bus & Containment Rule
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_event_bus" "sandbox_bus" {
  name = "agent-governance-bus-${var.environment}"

  tags = {
    Name = "agent-governance-bus"
  }
}

resource "aws_cloudwatch_event_rule" "kill_switch_rule" {
  name           = "agent-circuit-breaker-rule-${var.environment}"
  description    = "Trips on anomalous activity, prompt extraction, or cost overruns"
  event_bus_name = aws_cloudwatch_event_bus.sandbox_bus.name

  event_pattern = jsonencode({
    "source"      : ["sandbox.security", "sandbox.finops"],
    "detail-type" : ["CircuitBreakerTripped", "BudgetLimitExceeded"]
  })

  tags = {
    Name = "agent-circuit-breaker-rule"
  }
}

# -----------------------------------------------------------------------------
# Emergency Kill-Switch Lambda Function
# -----------------------------------------------------------------------------

# Package Lambda code into a zip archive
data "archive_file" "kill_switch_zip" {
  type        = "zip"
  source_file = "${path.module}/../../../src/kill_switch/handler.py"
  output_path = "${path.module}/kill_switch_payload.zip"
}

# Lambda Execution IAM Role
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "kill_switch_role" {
  name               = "circuit-breaker-lambda-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json

  tags = {
    Name = "circuit-breaker-lambda-role"
  }
}

# --- Scoped IAM Permissions: Stopping Tasks, Quarantining Agent Role, and X-Ray ---
data "aws_iam_policy_document" "kill_switch_perms" {
  #checkov:skip=CKV_AWS_111: "Write access strictly scoped to quarantine targeted agent role and tasks"
  #checkov:skip=CKV_AWS_356: "ecs:ListTasks and X-Ray telemetry require wildcard resource scoping by AWS design"

  statement {
    sid    = "CloudWatchLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
  }

  statement {
    sid    = "XRayTelemetry"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords"
    ]
    resources = ["*"]
  }

  statement {
    sid       = "QuarantineAgentRole"
    effect    = "Allow"
    actions   = ["iam:PutRolePolicy"]
    resources = [var.agent_task_role_arn]
  }

  statement {
    sid       = "StopAgentTasks"
    effect    = "Allow"
    actions   = ["ecs:StopTask"]
    resources = ["arn:aws:ecs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:task/${var.ecs_cluster_name}/*"]
  }

  statement {
    sid       = "DiscoverClusterTasks"
    effect    = "Allow"
    actions   = ["ecs:ListTasks"]
    resources = ["*"]
  }
}

# --- Emergency Kill-Switch Lambda Function ---
resource "aws_lambda_function" "kill_switch" {
  #checkov:skip=CKV_AWS_115: "Function concurrency limit not required for low-frequency circuit breaker"
  #checkov:skip=CKV_AWS_116: "EventBridge target retries serve as DLQ mechanism for breaker function"
  #checkov:skip=CKV_AWS_117: "Lambda requires AWS control plane API access to stop ECS tasks and attach IAM policies"
  #checkov:skip=CKV_AWS_272: "Code-signing not configured for sandbox Lambda module"

  filename         = data.archive_file.kill_switch_zip.output_path
  function_name    = "agent-circuit-breaker-${var.environment}"
  role             = aws_iam_role.kill_switch_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  source_code_hash = data.archive_file.kill_switch_zip.output_base64sha256

  # Fix CKV_AWS_173: Encrypt Lambda environment variables with Customer Managed KMS Key
  kms_key_arn = var.kms_key_arn

  # Fix CKV_AWS_50: Enable Active X-Ray distributed tracing
  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      CLUSTER_NAME    = var.ecs_cluster_name
      AGENT_ROLE_NAME = var.agent_task_role_name
    }
  }

  tags = {
    Name = "agent-circuit-breaker"
  }
}


# EventBridge Target linking the Rule to the Lambda
resource "aws_cloudwatch_event_target" "lambda_target" {
  event_bus_name = aws_cloudwatch_event_bus.sandbox_bus.name
  rule           = aws_cloudwatch_event_rule.kill_switch_rule.name
  target_id      = "KillSwitchLambdaTarget"
  arn            = aws_lambda_function.kill_switch.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.kill_switch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.kill_switch_rule.arn
}
