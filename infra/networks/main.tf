locals {
  network_config = module.config.networks[var.name]
  tags = merge(
    module.config.default_tags,
    { Network = var.name }
  )
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6"
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
    tags = local.tags
  }
}

module "vpc" {
  source = "../modules/vpc"

  name                    = var.name
  availability_zone_count = local.network_config.availability_zone_count
  enable_nat_gateway      = local.network_config.enable_nat_gateway
  use_native_nat          = local.network_config.use_native_nat
}

module "config" {
  source = "../config"
}
