locals {
  database_config = module.config.databases[var.name]
}
module "config" {
  source = "../../config"
}

data "aws_db_instance" "this" {
  count                  = local.database_config == "rds" ? 1 : 0
  db_instance_identifier = var.name
  tags                   = module.config.default_tags
}

data "aws_security_group" "external" {
  count = local.database_config == "rds" ? 1 : 0
  name  = "database-${var.name}-external-sg"
}
