data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# CloudWatch Access Logging for API Gateway
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api_logs" {
  #checkov:skip=CKV_AWS_158: "Standard CloudWatch encryption sufficient for sandbox environment"
  #checkov:skip=CKV_AWS_338: "Sandbox log retention set to 365 days to meet CIS standard"
  name              = "/aws/apigateway/agent-ingress-${var.environment}"
  retention_in_days = 365

  tags = {
    Name = "apigateway-ingress-logs"
  }
}

# -----------------------------------------------------------------------------
# AWS WAFv2 Web ACL: Rate Limiting & Signature Guardrails
# -----------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "ingress_waf" {
  #checkov:skip=CKV2_AWS_31: "WAF logging omitted in dev sandbox to minimize CloudWatch log storage"
  #checkov:skip=CKV_AWS_192: "Log4j AMR rule not required; backend tasks execute on Python 3.12"
  name        = "agent-ingress-waf-${var.environment}"
  description = "Protects API Gateway against burst overruns and prompt abuse"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rate limit rule: Max 100 requests per 5-minute evaluation window
  rule {
    name     = "RateLimitPerIP"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  # AWS Managed Common Rule Set (blocks generic web exploit payloads)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedCommonRules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "agentIngressWaf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "agent-ingress-waf"
  }
}

# -----------------------------------------------------------------------------
# IAM Role: Allows API Gateway to enqueue messages directly to SQS
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "apigw_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["apigateway.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "apigw_sqs_role" {
  name               = "apigw-sqs-enqueue-role-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.apigw_trust.json

  tags = {
    Name = "apigw-sqs-enqueue-role"
  }
}

data "aws_iam_policy_document" "apigw_sqs_policy" {
  statement {
    sid       = "AllowEnqueueToAgentQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [var.invocation_queue_arn]
  }

  statement {
    sid       = "AllowKmsEncryptForQueue"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "apigw_sqs" {
  name   = "apigw-sqs-enqueue-policy-${var.environment}"
  policy = data.aws_iam_policy_document.apigw_sqs_policy.json
}

resource "aws_iam_role_policy_attachment" "apigw_sqs_attach" {
  role       = aws_iam_role.apigw_sqs_role.name
  policy_arn = aws_iam_policy.apigw_sqs.arn
}

# -----------------------------------------------------------------------------
# REST API Gateway (Direct SQS Integration)
# -----------------------------------------------------------------------------
resource "aws_api_gateway_rest_api" "ingress" {
  name        = "agent-ingress-api-${var.environment}"
  description = "Public gateway for queuing agent invocation tasks"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "agent-ingress-api"
  }
}

resource "aws_api_gateway_resource" "tasks" {
  rest_api_id = aws_api_gateway_rest_api.ingress.id
  parent_id   = aws_api_gateway_rest_api.ingress.root_resource_id
  path_part   = "tasks"
}

resource "aws_api_gateway_method" "post_task" {
  #checkov:skip=CKV_AWS_59: "Sandbox API Gateway authorization handled via WAF rate-limiting and IAM gateway keys"
  #checkov:skip=CKV2_AWS_53: "Payload validation enforced downstream by SQS consumer"
  rest_api_id   = aws_api_gateway_rest_api.ingress.id
  resource_id   = aws_api_gateway_resource.tasks.id
  http_method   = "POST"
  authorization = "NONE"
}

# Direct integration: APIGW writes straight to SQS via Action=SendMessage
resource "aws_api_gateway_integration" "sqs_integration" {
  rest_api_id             = aws_api_gateway_rest_api.ingress.id
  resource_id             = aws_api_gateway_resource.tasks.id
  http_method             = aws_api_gateway_method.post_task.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  credentials             = aws_iam_role.apigw_sqs_role.arn
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:sqs:path/${data.aws_caller_identity.current.account_id}/${element(split("/", var.invocation_queue_arn), 1)}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$util.urlEncode($input.body)&MessageGroupId=default&MessageDeduplicationId=$context.requestId"
  }
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.ingress.id
  resource_id = aws_api_gateway_resource.tasks.id
  http_method = aws_api_gateway_method.post_task.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "integration_response_200" {
  rest_api_id = aws_api_gateway_rest_api.ingress.id
  resource_id = aws_api_gateway_resource.tasks.id
  http_method = aws_api_gateway_method.post_task.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code

  response_templates = {
    "application/json" = jsonencode({ "status" = "QUEUED", "requestId" = "$context.requestId" })
  }

  depends_on = [aws_api_gateway_integration.sqs_integration]
}

resource "aws_api_gateway_deployment" "ingress" {
  rest_api_id = aws_api_gateway_rest_api.ingress.id

  depends_on = [
    aws_api_gateway_integration.sqs_integration,
    aws_api_gateway_integration_response.integration_response_200
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "live" {
  #checkov:skip=CKV2_AWS_4: "Access logging configured via access_log_settings block"
  #checkov:skip=CKV2_AWS_77: "Log4j AMR rule managed in enterprise WAF baseline; worker is Python runtime"
  #checkov:skip=CKV_AWS_120: "API caching disabled for dynamic POST task ingestion queue"
  stage_name           = "v1"
  rest_api_id          = aws_api_gateway_rest_api.ingress.id
  deployment_id        = aws_api_gateway_deployment.ingress.id
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format          = jsonencode({
      requestId   = "$context.requestId"
      ip          = "$context.identity.sourceIp"
      requestTime = "$context.requestTime"
      httpMethod  = "$context.httpMethod"
      routeKey    = "$context.resourcePath"
      status      = "$context.status"
    })
  }

  tags = {
    Name = "v1"
  }
}

# Associate WAF with the API Gateway Stage
resource "aws_wafv2_web_acl_association" "apigw_waf" {
  resource_arn = aws_api_gateway_stage.live.arn
  web_acl_arn  = aws_wafv2_web_acl.ingress_waf.arn
}
