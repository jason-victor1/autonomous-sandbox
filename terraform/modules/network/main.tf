# --- VPC Definition ---
resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11: "VPC flow logs disabled for sandbox dev environment"
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "autonomous-sandbox-vpc"
  }
}

# --- Default Security Group Hardening (CIS Benchmark) ---
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "default-neutralized"
  }
}

# --- Public Subnets & Ingress Route ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "sandbox-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "public-subnet-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "public-rt"
    Tier = "public"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private Subnets (Workload Tier) ---
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "private-subnet-${count.index + 1}"
    Tier = "private"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt"
    Tier = "private"
  }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- Isolated Subnets (Hermetic AI / Inference Tier) ---
resource "aws_subnet" "isolated" {
  count             = length(var.isolated_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.isolated_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "isolated-ai-subnet-${count.index + 1}"
    Tier = "isolated"
  }
}

resource "aws_route_table" "isolated" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "isolated-rt"
    Tier = "isolated"
  }
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated.id
}

# --- Micro-Segmented Baseline Security Group ---
resource "aws_security_group" "compute_isolated" {
  #checkov:skip=CKV2_AWS_5: "Security group attached dynamically to ECS tasks across module boundary"
  name        = "compute-isolated-sg"
  description = "Isolated security group; communicates strictly via peer security groups"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "compute-isolated-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "https_outbound" {
  security_group_id = aws_security_group.compute_isolated.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Restrict egress strictly to internal VPC endpoints on HTTPS"
}



