module "service" {
  count     = local.env_config.type == "aws" ? 1 : 0
  source    = "../modules/service"
  name      = "${module.config.project_name}-${var.name}"
  image_tag = coalesce(local.image_tag, "hello-world:nanoserver")

  cluster_arn       = module.account_data.cluster_arn
  task_subnet_ids   = module.network_data.private_subnets
  lb_subnet_ids     = module.network_data.public_subnets
  db_external_sg_id = module.database_data.external_sg_id
  db_host           = module.database_data.db_host
  db_port           = module.database_data.db_port
  db_name           = module.database_data.db_name
  db_username       = module.database_data.db_username
  hosted_zone_id    = module.network_data.hosted_zone_id
  domain            = local.env_config.domain
  certificate_arn   = module.network_data.certificate_arns[local.env_config.certificate]
  desired_count     = var.desired_count
  is_temporary      = try(local.env_config.is_temporary, false)
}


