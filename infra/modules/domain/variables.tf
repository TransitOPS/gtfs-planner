variable "hosted_zone" {
  type        = string
  description = "Hosted zone to create"
}

variable "certificates" {
  type = map(object({
    subject_alternative_names = optional(list(string)),
  }))
}
