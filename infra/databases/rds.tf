
module "database" {
  count  = local.database_config.type == "rds" ? 1 : 0
  source = "../modules/rds-database"

  name              = var.name
  database_name     = local.database_config.postgres_database_name
  min_capacity      = try(local.database_config.min_capacity, 0)
  max_capacity      = try(local.database_config.max_capacity, 10)
  subnet_group_name = module.network_data.db_subnet_group_name
  private_subnets   = module.network_data.private_subnets
  is_temporary      = try(local.database_config.is_temporary, false)
}
