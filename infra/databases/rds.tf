
module "database" {
  count  = local.database_config.type == "rds" ? 1 : 0
  source = "../modules/rds-database"

  name              = var.name
  database_name     = module.config.project_name
  instance_class    = local.database_config.instance_class
  subnet_group_name = module.network_data.db_subnet_group_name
  private_subnets   = module.network_data.private_subnets
  multi_az          = local.database_config.multi_az
  is_temporary      = local.database_config.is_temporary
}
