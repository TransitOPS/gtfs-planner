variable "project_name" {
  type = string
}

variable "name" {
  type = string
}

variable "image_tag" {
  type = string
}

variable "domain" {
  type = string
}

variable "host" {
  type = string
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type = number
}

variable "db_name" {
  type = string
}

variable "db_username" {
  type = string
}

variable "geoapify_api_key" {
  type      = string
  sensitive = true
}
