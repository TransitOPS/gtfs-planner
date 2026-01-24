output "hosted_zone_nameservers" {
  value = aws_route53_zone.this.name_servers
}
