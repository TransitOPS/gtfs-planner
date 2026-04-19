variable "name" {
  type        = string
  description = "Name of the database to create"
}

variable "database_name" {
  type        = string
  description = "Name of the internal database"
}

variable "min_capacity" {
  type        = number
  description = "Minimum ACU capacity"
}

variable "max_capacity" {
  type        = number
  description = "Maximum ACU capacity"
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

variable "is_temporary" {
  type        = bool
  description = "Whether to treat this database as temporary"
  default     = false
}
