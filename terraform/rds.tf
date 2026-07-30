# RDS Postgres, private subnet, single-AZ Phase 1 baseline.
# Multi-AZ is an explicit, additive Phase 2 upgrade (roughly doubles cost) —
# not enabled here. See ceiba_aws_deployment_strategy.md §4.

resource "aws_db_subnet_group" "ceiba" {
  name = "ceiba-db-subnet-group"
  # AWS requires a DB subnet group to span at least two subnets in at least
  # two Availability Zones, unconditionally — this is not a Multi-AZ-only
  # requirement, it applies to a single-AZ instance too (AWS picks one AZ
  # from the group's subnets to actually launch into). aws_subnet.private_b
  # exists solely to satisfy this; it holds no other resource in Phase 1.
  # multi_az stays false below regardless — this only makes the subnet
  # group itself legal to create.
  subnet_ids = [aws_subnet.private.id, aws_subnet.private_b.id]

  tags = {
    Name = "ceiba-db-subnet-group"
  }
}

resource "aws_db_instance" "ceiba" {
  identifier     = "ceiba-prod"
  engine         = "postgres"
  engine_version = var.rds_postgres_version
  instance_class = var.rds_instance_class

  allocated_storage = var.rds_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.rds_db_name
  username = var.rds_master_username
  # No password variable, no random_password resource: RDS-managed master
  # password via Secrets Manager native integration. The real credential is
  # never in Terraform state as plaintext, never in git. The EC2 role reads
  # it at boot via iam.tf's ec2_secrets_read policy.
  manage_master_user_password = true

  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.ceiba.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 7
  backup_window           = "07:00-08:00" # UTC, low-traffic window for a pre-launch product
  maintenance_window      = "sun:08:30-sun:09:30"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "ceiba-prod-final-snapshot"

  tags = {
    Name = "ceiba-prod-postgres"
  }
}
