output "private_subnets" {
  value = data.aws_subnets.private.ids
}

output "public_subnets" {
  value = data.aws_subnets.public.ids
}

output "db_subnet_group_name" {
  # subnet group is named the same as the network
  value = var.name
}

output "hosted_zone_id" {
  value = data.aws_route53_zone.this.id
}

output "certificate_arns" {
  value = { for k, v in data.aws_acm_certificate.this : k => v.arn }
}
