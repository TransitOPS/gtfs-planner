module "docker_database" {
  count  = local.database_config.type == "docker" ? 1 : 0
  source = "../modules/docker-database"

  project_name  = module.config.project_name
  name          = var.name
  host          = local.database_config.host
  database_name = local.database_config.postgres_database_name
}
