variable "name" {
  type        = string
  description = "Name of the network to create"
}

variable "availability_zone_count" {
  type        = number
  description = "The number of availability zones to use for the VPC"
}

variable "enable_nat_gateway" {
  type        = bool
  default     = true
  description = "Whether to enable a NAT gateway"
}

variable "use_native_nat" {
  type        = bool
  default     = true
  description = "Whether to use AWS NAT gateways. Uses a fck-nat instance if false."
}
