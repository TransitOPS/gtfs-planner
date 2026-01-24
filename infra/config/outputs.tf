output "default_region" {
  value = local.default_region
}

output "default_tags" {
  value = {
    Project   = local.project_name
    Owner     = local.owner
    Terraform = true
    Workspace = terraform.workspace
  }
}

output "project_name" {
  value = local.project_name
}

output "owner" {
  value = local.owner
}

output "github_actions_role_name" {
  value = local.github_actions_role_name
}

output "github_repo" {
  value = regex("([^\\/]+\\/[^\\/]+$)", local.code_repository_url)[0]
}

output "accounts" {
  value = local.accounts
}

output "networks" {
  value = local.networks
}

output "databases" {
  value = local.databases
}

output "environments" {
  value = local.environments
}
