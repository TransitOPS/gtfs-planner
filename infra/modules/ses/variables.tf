variable "hosted_zone_id" {
  type        = string
  description = "Hosted Route53 zone ID to add our domain to"
}
variable "domain" {
  type        = string
  description = "Domain name to alias to the load balancer"
}
