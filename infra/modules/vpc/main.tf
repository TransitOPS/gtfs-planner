locals {
  vpc_cidr                = "10.0.0.0/20"
  availability_zone_count = var.availability_zone_count
  azs                     = slice(data.aws_availability_zones.available.names, 0, local.availability_zone_count)
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=b3fb14ff51b6e6714b6edc97972267950b66cb50"

  name = var.name
  cidr = local.vpc_cidr

  azs              = local.azs
  public_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  database_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + 4)]
  private_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k + 8)]

  enable_dns_hostnames = true
  enable_dns_support   = true

  create_database_subnet_group = local.availability_zone_count > 1

  enable_nat_gateway     = var.enable_nat_gateway && var.use_native_nat
  one_nat_gateway_per_az = true
}

module "nat" {
  source = "git::https://github.com/RaJiska/terraform-aws-fck-nat?ref=d5ef75950e3614daf71c50245c516965778edca5"
  count  = var.enable_nat_gateway && !var.use_native_nat ? length(local.azs) : 0

  name      = "${var.name}-nat-${local.azs[count.index]}"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnets[count.index]

  use_spot_instances = false
  instance_type      = "t4g.nano"
  attach_ssm_policy  = false
  ha_mode            = true

  update_route_tables = true
  route_tables_ids = {
    private = module.vpc.private_route_table_ids[count.index]
  }
}
