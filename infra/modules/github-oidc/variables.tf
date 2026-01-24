variable "github_actions_role_name" {
  type        = string
  description = "Name of the role for GitHub Actions to assume"
}

variable "github_repo" {
  type        = string
  description = "Name of the GitHub repo which will be assuming the role: organization/project format"
}

variable "permissions" {
  type        = list(string)
  description = "Permissions to grant to the assumed role"
  default     = []
}
