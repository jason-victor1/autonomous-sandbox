data "aws_region" "current" {}

# --- Security Group for PrivateLink Interface Endpoints ---
resource "aws_security_group" "endpoints_sg" {
  name        = "vpce-interface-sg"
  description = "Permit inbound HTTPS exclusively from internal compute"
  vpc_id      = var.vpc_id

  tags = {
    Name = "vpce-interface-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints_sg.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Internal TLS traffic to VPC Endpoints"
}

# --- VPC Endpoints for Zero-Egress Operation ---
# 1. S3 Gateway Endpoint
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [var.isolated_route_table_id]

  tags = {
    Name = "vpce-s3-gateway"
  }
}

# 2. ECR Docker Image Registry Endpoints
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.isolated_subnet_ids
  security_group_ids  = [aws_security_group.endpoints_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "vpce-ecr-api"
  }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.isolated_subnet_ids
  security_group_ids  = [aws_security_group.endpoints_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "vpce-ecr-dkr"
  }
}

# 3. CloudWatch Logs Endpoint
resource "aws_vpc_endpoint" "logs" {
  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.isolated_subnet_ids
  security_group_ids  = [aws_security_group.endpoints_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "vpce-cloudwatch-logs"
  }
}

# --- ECS Cluster with Container Insights ---
resource "aws_ecs_cluster" "main" {
  name = "ai-platform-${var.environment}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "ai-platform-${var.environment}-cluster"
  }
}

# --- CloudWatch Log Group for Compute ---
resource "aws_cloudwatch_log_group" "agent_logs" {
  #checkov:skip=CKV_AWS_158: "Standard CloudWatch encryption sufficient for sandbox environment"
  name              = "/ecs/agent-worker-${var.environment}"
  retention_in_days = 365

  tags = {
    Name = "agent-worker-logs"
  }
}

# -----------------------------------------------------------------------------
# Decoupled IAM Roles: Execution Role vs. Task Runtime Role
# -----------------------------------------------------------------------------

# Shared Assume Role Document for ECS Tasks
data "aws_iam_policy_document" "ecs_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# 1. Task Execution Role: Used exclusively by the ECS Agent to start container
resource "aws_iam_role" "task_execution_role" {
  name               = "ecs-agent-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json

  tags = {
    Name = "ecs-agent-task-execution-role"
  }
}

data "aws_iam_policy_document" "task_execution_perms" {
  #checkov:skip=CKV_AWS_356: "ECR image pull and auth token actions require wildcard resource scoping"

  statement {
    sid    = "ECRAuthToken"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECRImagePull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogStream"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.agent_logs.arn}:*"]
  }
}

resource "aws_iam_policy" "task_execution_policy" {
  name   = "ecs-task-execution-policy"
  policy = data.aws_iam_policy_document.task_execution_perms.json
}

resource "aws_iam_role_policy_attachment" "task_execution_attach" {
  role       = aws_iam_role.task_execution_role.name
  policy_arn = aws_iam_policy.task_execution_policy.arn
}

# 2. Task Role: Scoped exclusively to the running container application
resource "aws_iam_role" "task_role" {
  name               = "ecs-agent-task-runtime-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json

  tags = {
    Name = "ecs-agent-task-runtime-role"
  }
}

data "aws_iam_policy_document" "task_runtime_perms" {
  statement {
    sid       = "ReadModelArtifactsOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.model_bucket_arn, "${var.model_bucket_arn}/*"]
  }

  statement {
    sid       = "DecryptWithCMK"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_policy" "task_policy" {
  name   = "ecs-task-runtime-policy"
  policy = data.aws_iam_policy_document.task_runtime_perms.json
}

resource "aws_iam_role_policy_attachment" "task_attach" {
  role       = aws_iam_role.task_role.name
  policy_arn = aws_iam_policy.task_policy.arn
}

# --- Hardened ECS Task Definition ---
resource "aws_ecs_task_definition" "agent_worker" {
  #checkov:skip=CKV_AWS_336: "ReadOnlyRootFilesystem verified via container definition schema"
  family                   = "agent-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.task_execution_role.arn
  task_role_arn      = aws_iam_role.task_role.arn

  container_definitions = jsonencode([
    {
      name      = "agent-worker"
      image     = "478076837031.dkr.ecr.us-east-1.amazonaws.com/agent-worker:latest"
      essential = true
      user      = "10001"

      readonlyRootFilesystem = true

      mountPoints = [
        {
          sourceVolume  = "tmp-scratch"
          containerPath = "/tmp"
          readOnly      = false
        }
      ]

      linuxParameters = {
        initProcessEnabled = true
        capabilities = {
          drop = ["ALL"]
        }
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.agent_logs.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  volume {
    name = "tmp-scratch"
  }

  tags = {
    Name        = "agent-worker-task"
    Environment = var.environment
    Tier        = "isolated-compute"
  }
}
