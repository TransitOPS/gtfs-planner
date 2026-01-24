module "config" {
  source = "../../config"
}

data "aws_ecs_cluster" "this" {
  cluster_name = module.config.project_name
}
