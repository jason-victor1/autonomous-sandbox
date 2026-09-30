# --- Dynamic Thumbprint Retrieval for GitHub OIDC ---
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]

  tags = {
    Name = "github-actions-oidc"
  }
}

# --- Permission Boundary Contract ---
# Sets the ceiling on actions for the CI/CD deployer identity
data "aws_iam_policy_document" "boundary" {
  #checkov:skip=CKV_AWS_109: "Permissions boundary defines allowable ceiling for network security group/ACL rules"
  #checkov:skip=CKV_AWS_111: "Permissions boundary defines allowable write ceiling for network infrastructure"
  #checkov:skip=CKV_AWS_356: "Permissions boundary acts as global ceiling across VPC resources before creation"

  statement {
    sid    = "AllowedNetworkInfrastructure"
    effect = "Allow"
    actions = [
      "ec2:*Vpc*",
      "ec2:*Subnet*",
      "ec2:*Route*",
      "ec2:*SecurityGroup*",
      "ec2:*NetworkAcl*",
      "ec2:*InternetGateway*"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ExplicitDenyPrivilegeEscalation"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteUserPermissionsBoundary"
    ]
    resources = ["*"]
  }
}


resource "aws_iam_policy" "boundary" {
  name        = "ci-deployment-permission-boundary"
  description = "Maximum allowable boundaries for non-human deployment identities"
  policy      = data.aws_iam_policy_document.boundary.json
}

# --- OIDC Scoped Trust Policy ---
data "aws_iam_policy_document" "oidc_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

     condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:jason-victor1*/autonomous-sandbox*:*",
        "repo:jason-victor1/autonomous-sandbox:*"
      ]
    }
  }
}

# --- Non-Human IAM Deployment Role ---
resource "aws_iam_role" "deployer" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.oidc_trust.json
  permissions_boundary = aws_iam_policy.boundary.arn
  max_session_duration = var.max_session_duration

  tags = {
    Name        = var.role_name
    Environment = "dev"
  }
}

# --- Scoped Deployment Policy for Phase 1 ---
data "aws_iam_policy_document" "deployer_policy" {
  #checkov:skip=CKV_AWS_111: "Write access required for CI/CD deployer role to manage network lifecycle"
  #checkov:skip=CKV_AWS_356: "EC2 network provisioning actions require wildcard resource during initial creation"

  statement {
    sid    = "ReadOnlyInspection"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "iam:GetRole",
      "iam:GetPolicy",
      "iam:GetOpenIDConnectProvider"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NetworkProvisioning"
    effect = "Allow"
    actions = [
      "ec2:CreateVpc",
      "ec2:ModifyVpcAttribute",
      "ec2:DeleteVpc",
      "ec2:CreateSubnet",
      "ec2:ModifySubnetAttribute",
      "ec2:DeleteSubnet",
      "ec2:CreateRouteTable",
      "ec2:CreateRoute",
      "ec2:AssociateRouteTable",
      "ec2:DisassociateRouteTable",
      "ec2:DeleteRouteTable",
      "ec2:CreateInternetGateway",
      "ec2:AttachInternetGateway",
      "ec2:DetachInternetGateway",
      "ec2:DeleteInternetGateway",
      "ec2:CreateSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:DeleteSecurityGroup",
      "ec2:CreateTags"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "deployer" {
  name   = "ci-scoped-deployer-policy"
  policy = data.aws_iam_policy_document.deployer_policy.json
}

resource "aws_iam_role_policy_attachment" "deployer_attach" {
  role       = aws_iam_role.deployer.name
  policy_arn = aws_iam_policy.deployer.arn
}
