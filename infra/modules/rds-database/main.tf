locals {
  master_username = "root"
}

data "aws_rds_engine_version" "this" {
  engine       = "aurora-postgresql"
  version      = var.postgres_version
  default_only = true
  latest       = true
}

module "rds" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-rds-aurora?ref=2c3946c8191278ad974bbb077da5e03986e24f4d"

  name = var.name

  engine                   = data.aws_rds_engine_version.this.engine
  engine_version           = data.aws_rds_engine_version.this.version
  engine_lifecycle_support = "open-source-rds-extended-support-disabled"

  database_name   = var.database_name
  master_username = local.master_username

  vpc_id               = data.aws_db_subnet_group.this.vpc_id
  db_subnet_group_name = var.subnet_group_name

  storage_encrypted       = true
  backup_retention_period = 30

  iam_database_authentication_enabled = true
  security_group_name                 = "database-${var.name}-sg"
  security_group_ingress_rules = {
    from_external = {
      referenced_security_group_id = aws_security_group.external.id
    }
  }

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 30
  enabled_cloudwatch_logs_exports        = ["iam-db-auth-error"]

  cluster_instance_class = "db.serverless"
  serverlessv2_scaling_configuration = {
    min_capacity             = var.min_capacity
    max_capacity             = var.max_capacity
    seconds_until_auto_pause = 300
  }

  instances = {
    writer = {}
  }

  apply_immediately   = var.is_temporary
  skip_final_snapshot = var.is_temporary
  deletion_protection = !var.is_temporary
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
data "aws_db_subnet_group" "this" {
  name = var.subnet_group_name
}
