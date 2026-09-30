module "network" {
  source = "../../modules/network"

  vpc_cidr              = "10.0.0.0/16"
  availability_zones    = ["${var.aws_region}a", "${var.aws_region}b"]
  public_subnet_cidrs   = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnet_cidrs  = ["10.0.10.0/24", "10.0.20.0/24"]
  isolated_subnet_cidrs = ["10.0.100.0/24", "10.0.200.0/24"]
}

module "identity" {
  source = "../../modules/identity"

  github_org           = var.github_org
  github_repo          = var.github_repo
  role_name            = "gh-actions-deployer-role"
  max_session_duration = 3600
}

module "data" {
  source = "../../modules/data"

  environment   = "dev"
  bucket_prefix = "sandbox-model-artifacts"
}

module "compute" {
  source = "../../modules/compute"

  environment             = "dev"
  vpc_id                  = module.network.vpc_id
  vpc_cidr                = "10.0.0.0/16"
  isolated_subnet_ids     = module.network.isolated_subnet_ids
  isolated_route_table_id = module.network.isolated_route_table_id
  model_bucket_arn        = module.data.bucket_arn
  kms_key_arn             = module.data.kms_key_arn
}

module "circuit_breaker" {
  source = "../../modules/circuit_breaker"

  environment          = "dev"
  ecs_cluster_name     = module.compute.cluster_name
  ecs_cluster_arn      = module.compute.cluster_id
  agent_task_role_name = module.compute.task_role_name
  agent_task_role_arn  = module.compute.task_role_arn
  kms_key_arn          = module.data.kms_key_arn
}

module "ingress" {
  source = "../../modules/ingress"

  environment          = "dev"
  invocation_queue_arn = module.circuit_breaker.invocation_queue_arn
  kms_key_arn          = module.data.kms_key_arn
}
