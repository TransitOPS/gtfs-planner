module "endpoints" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git//modules/vpc-endpoints?ref=b3fb14ff51b6e6714b6edc97972267950b66cb50"

  vpc_id                = module.vpc.vpc_id
  create_security_group = true
  security_group_name   = "vpc-endpoints"

  endpoints = {
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      tags         = { Name = "s3-vpc-endpoint" }
    }

    # TODO think about enabling when the service is ready
    # - more secure than going over the NAT gateway, but
    # - additional cost and we need the NAT gateway anyways
    #   for external traffic
    #   rds = {
    #     service = "rds"
    #     tags    = { Name = "rds-vpc-endpoint" }
    #     subnet_ids = module.vpc.private_subnets
    #   }
  }
}
