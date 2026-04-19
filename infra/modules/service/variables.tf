variable "name" {
  type        = string
  description = "Name of the environment (dev, prod, &c)"
}
variable "image_tag" {
  type        = string
  description = "Tag to deploy"
}
variable "desired_count" {
  type        = number
  description = "Number of tasks"
  default     = null
}
variable "cluster_arn" {
  type        = string
  description = "ARN of the cluster to add the service to"
}
variable "task_subnet_ids" {
  description = "Subnet IDs to use for the service tasks"
  type        = list(string)
}
variable "lb_subnet_ids" {
  description = "Subnet IDs to use for the load balancer"
  type        = list(string)
}
variable "db_external_sg_id" {
  type        = string
  description = "Security group used by external resources for connecting to the database"
}
variable "db_host" {
  type        = string
  description = "Hostname of the database"
}
variable "db_port" {
  type        = number
  description = "Port number of the database"
}
variable "db_name" {
  type        = string
  description = "Name of the database on the server"
}
variable "db_username" {
  type        = string
  description = "Name of the user to use when connecting (IAM auth)"
}
variable "app_cpu" {
  type    = number
  default = 256
}
variable "app_memory" {
  type    = number
  default = 512
}
variable "ssl_policy" {
  type    = string
  default = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}
variable "hosted_zone_id" {
  type        = string
  description = "Hosted Route53 zone ID to add our domain to"
}
variable "domain" {
  type        = string
  description = "Domain name to alias to the load balancer"
}
variable "certificate_arn" {
  type = string
}
variable "is_temporary" {
  type        = bool
  description = "Whether to treat this service as expendable"
  default     = false
}
variable "geoapify_api_key" {
  type      = string
  sensitive = true
}
