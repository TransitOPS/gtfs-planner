variable "name" {
  type        = string
  description = "Name of the GTFS Planner application environment to create"
}

variable "image_tag" {
  type        = string
  description = "Full tag to deploy"
  default     = null
}

variable "desired_count" {
  type        = number
  description = "Number of instances"
  default     = null
}
