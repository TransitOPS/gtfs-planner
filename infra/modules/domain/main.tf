resource "aws_route53_zone" "this" {
  name = var.hosted_zone

  # checkov:skip=CKV2_AWS_38:not worrying about DNSSEC for now
  # checkov:skip=CKV2_AWS_39:TODO enable query logging
}

module "certificate" {
  source = "../certificate"

  for_each = var.certificates

  domain_name               = each.key
  subject_alternative_names = try(each.value.subject_alternative_names, [])
  zone_id                   = aws_route53_zone.this.id
}
