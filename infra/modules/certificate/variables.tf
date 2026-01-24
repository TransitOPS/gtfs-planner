variable "domain_name" {
  type = string
}

variable "subject_alternative_names" {
  type    = list(any)
  default = []
}

variable "zone_id" {
  type = string
}
