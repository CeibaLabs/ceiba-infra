# Network layout per ceiba_aws_deployment_strategy.md §3.
#
# Public subnet: EC2 app host only (Caddy TLS + control-plane + runtime +
# self-hosted Redis).
# Private subnet: RDS (and ElastiCache in Phase 2). No NAT Gateway — nothing
# in the private subnet ever initiates outbound internet traffic, it only
# accepts inbound from the EC2 security group. See docs/ADR-0001-no-nat-gateway.md.

resource "aws_vpc" "ceiba" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "ceiba-vpc"
  }
}

resource "aws_internet_gateway" "ceiba" {
  vpc_id = aws_vpc.ceiba.id

  tags = {
    Name = "ceiba-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.ceiba.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "ceiba-public"
  }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.ceiba.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "ceiba-private"
  }
}

# Second private subnet, second AZ. Not a Multi-AZ upgrade — AWS requires a
# DB subnet group to span at least two AZs regardless of whether the RDS
# instance itself is Multi-AZ (see rds.tf). Nothing is deployed into this
# subnet in Phase 1; it mirrors aws_subnet.private exactly (no
# map_public_ip_on_launch, no route-table association — stays on the VPC's
# default local-only route table, consistent with ADR-0001-no-nat-gateway.md).
resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.ceiba.id
  cidr_block        = var.private_subnet_b_cidr
  availability_zone = var.availability_zone_b

  tags = {
    Name = "ceiba-private-b"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.ceiba.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ceiba.id
  }

  tags = {
    Name = "ceiba-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private subnet deliberately keeps the VPC's default (local-only) route
# table — no route to the internet gateway, no NAT Gateway route. RDS and
# (Phase 2) ElastiCache only ever need to be reached FROM the EC2 security
# group, never to reach OUT.

# --- Security groups -------------------------------------------------------

resource "aws_security_group" "ec2" {
  name        = "ceiba-ec2-sg"
  description = "Ceiba app host: 80/443 from anywhere, no inbound SSH (SSM Session Manager only)."
  vpc_id      = aws_vpc.ceiba.id

  ingress {
    description = "HTTP (redirects to HTTPS via Caddy)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound (package installs, Docker pulls, RDS, Stripe/Clerk/Resend API calls)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ceiba-ec2-sg"
  }
}

resource "aws_security_group" "rds" {
  name        = "ceiba-rds-sg"
  description = "RDS Postgres: inbound 5432 from the EC2 security group only."
  vpc_id      = aws_vpc.ceiba.id

  ingress {
    description     = "Postgres from Ceiba app host"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    description = "No outbound needed - RDS never initiates outbound traffic."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = []
  }

  tags = {
    Name = "ceiba-rds-sg"
  }
}

# Phase 2 (not created here): an aws_security_group.elasticache mirroring
# aws_security_group.rds's shape (6379 from aws_security_group.ec2.id only)
# when self-hosted Redis is replaced by ElastiCache.
