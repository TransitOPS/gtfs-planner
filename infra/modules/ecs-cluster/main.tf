module "ecs_cluster" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-ecs//modules/cluster?ref=b8e633547ca4bc628af7db96b0044869c44b08e4"

  name = var.name

  create_cloudwatch_log_group = false

  setting = [
    { name = "containerInsights", value = "disabled" }
  ]

  default_capacity_provider_strategy = {
    FARGATE_SPOT = {
      weight = var.use_spot ? 1 : 0
    }
    FARGATE = {
      weight = var.use_spot ? 0 : 1
    }
  }
}
