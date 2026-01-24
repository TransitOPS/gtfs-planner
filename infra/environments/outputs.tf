output "task_network_configuration" {
  value = try(module.service[0].task_network_configuration, null)
}

output "host" {
  value = try(local.env_config.host, null)
}
