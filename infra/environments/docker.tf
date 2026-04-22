module "docker_service" {
  count  = local.env_config.type == "docker" ? 1 : 0
  source = "../modules/docker-service"

  project_name = module.config.project_name
  name         = var.name
  image_tag    = coalesce(local.image_tag, "hello-world:nanoserver")

  host             = local.env_config.host
  db_host          = module.database_data.db_host
  db_port          = module.database_data.db_port
  db_name          = module.database_data.db_name
  db_username      = module.database_data.db_username
  domain           = local.env_config.domain
  geoapify_api_key = local.env_config.geoapify_api_key
}

resource "aws_route53_record" "lb" {
  count   = local.env_config.type == "docker" ? 1 : 0
  zone_id = module.network_data.hosted_zone_id
  name    = local.env_config.domain
  type    = "A"
  ttl     = 300
  records = [local.env_config.host]

  # checkov:skip=CKV2_AWS_23:attached resource is external to AWS
}
