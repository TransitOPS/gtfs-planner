locals {
  master_username = "root"
}

module "rds" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds?ref=578c95b19abf30b9b1068dd54025ac8e6df3212f"

  identifier                      = var.name
  parameter_group_use_name_prefix = false
  option_group_use_name_prefix    = false

  engine                   = "postgres"
  engine_version           = var.postgres_version
  engine_lifecycle_support = "open-source-rds-extended-support-disabled"

  family               = "postgres${var.postgres_version}"
  major_engine_version = var.postgres_version

  db_name  = var.name
  username = local.master_username

  db_subnet_group_name = var.subnet_group_name
  multi_az             = var.multi_az

  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = var.storage_type
  iops              = var.iops

  iam_database_authentication_enabled = true
  vpc_security_group_ids              = [aws_security_group.this.id]

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 30
  enabled_cloudwatch_logs_exports        = ["iam-db-auth-error"]

  apply_immediately   = var.is_temporary
  skip_final_snapshot = var.is_temporary
  deletion_protection = !var.is_temporary
}

resource "aws_security_group" "this" {
  name        = "database-${var.name}-sg"
  description = "Security group containing the RDS database for ${var.name}"
  vpc_id      = data.aws_db_subnet_group.this.vpc_id

  tags = {
    Name = "database-${var.name}-sg"
  }
  # checkov:skip=CKV2_AWS_5:it's connected to the database, but through a module
}

resource "aws_security_group" "external" {
  name        = "database-${var.name}-external-sg"
  description = "Security group for resources which are given access to the ${var.name} RDS database"
  vpc_id      = data.aws_db_subnet_group.this.vpc_id

  tags = {
    Name = "database-${var.name}-external-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "from_external" {
  security_group_id = aws_security_group.this.id
  description       = "Provide incoming access to the RDS database"

  referenced_security_group_id = aws_security_group.external.id
  ip_protocol                  = "tcp"
  from_port                    = module.rds.db_instance_port
  to_port                      = module.rds.db_instance_port
}

data "aws_db_subnet_group" "this" {
  name = var.subnet_group_name
}
