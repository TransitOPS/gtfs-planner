locals {
  database_config = module.config.databases[var.name]
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "2.7.1"
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
      { Database = var.name }
    )
  }
}

module "config" {
  source = "../config"
}

module "network_data" {
  source = "../networks/data"

  name = local.database_config.network_name
}
