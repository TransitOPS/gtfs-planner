locals {
  network_config = module.config.networks[var.name]
  tags           = merge(module.config.default_tags, { Network = var.name })
}

module "config" {
  source = "../../config"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_vpc" "this" {
  state = "available"
  filter {
    name   = "tag:Network"
    values = [var.name]
  }
  filter {
    name   = "tag:Project"
    values = [module.config.project_name]
  }
  filter {
    name   = "tag:Owner"
    values = [module.config.owner]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "tag:Network"
    values = [var.name]
  }
  filter {
    name   = "tag:Name"
    values = [for name in data.aws_availability_zones.available.names : "${var.name}-private-${name}"]
  }
  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "Must have at least 1 private subnet"
    }
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  filter {
    name   = "tag:Network"
    values = [var.name]
  }
  filter {
    name   = "tag:Name"
    values = [for name in data.aws_availability_zones.available.names : "${var.name}-public-${name}"]
  }
  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "Must have at least 1 public subnet"
    }
  }
}

data "aws_route53_zone" "this" {
  name = "${local.network_config.hosted_zone}."
  tags = local.tags
}

data "aws_acm_certificate" "this" {
  for_each = local.network_config.certificates

  domain   = each.key
  statuses = ["ISSUED"]
  types    = ["AMAZON_ISSUED"]
  tags     = local.tags
}

