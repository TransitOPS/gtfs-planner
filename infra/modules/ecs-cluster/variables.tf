variable "name" {
  type        = string
  description = "Name of the ECS cluster"
}

variable "use_spot" {
  type        = bool
  description = "Whether to use spot instances for Fargate capacity"
  default     = false
}
