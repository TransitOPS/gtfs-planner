variable "name" {
  type        = string
  description = "Name of the database to create"
}

variable "database_name" {
  type        = string
  description = "Name of the internal database"
}

variable "instance_class" {
  type        = string
  description = "Type of instance to create"
}

variable "subnet_group_name" {
  type        = string
  description = "Database subnet group name to use"
}

variable "private_subnets" {
  type        = list(string)
  description = "Private subnet IDs to use for Lambda functions"
}

variable "postgres_version" {
  type        = string
  description = "Major version of PostgreSQL to use"
  default     = "17"
}

variable "multi_az" {
  type        = bool
  description = "Whether to run in a multi-AZ configuration"
  default     = true
}

variable "allocated_storage" {
  type        = number
  description = "GB of storage to allocate"
  default     = 20
}

variable "storage_type" {
  type    = string
  default = "gp3"
}

variable "iops" {
  type    = number
  default = null
}

variable "is_temporary" {
  type        = bool
  description = "Whether to treat this database as temporary"
  default     = false
}
