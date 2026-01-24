locals {
  project_name = module.config.project_name
  env_config   = module.config.environments[var.name]
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6"
    }
    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }

  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
provider "aws" {
  region = module.config.default_region
  default_tags {
    tags = merge(
      module.config.default_tags,
      { Environment = var.name }
    )
  }
}

module "account_data" {
  source = "../accounts/data"
}

module "network_data" {
  source = "../networks/data"
  name   = local.env_config.network_name
}

module "database_data" {
  source = "../databases/data"
  name   = local.env_config.database_name
}

module "config" {
  source = "../config"
}

module "ses" {
  source = "../modules/ses"

  domain         = local.env_config.domain
  hosted_zone_id = module.network_data.hosted_zone_id
}
