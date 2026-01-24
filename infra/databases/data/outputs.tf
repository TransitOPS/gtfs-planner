output "external_sg_id" {
  value = try(data.aws_security_group.external[0].id, null)
}
output "db_host" {
  value = try(data.aws_db_instance.this[0].address, "${module.config.project_name}-database-${var.name}")
}
output "db_port" {
  value = try(data.aws_db_instance.this[0].port, 5432)
}
output "db_name" {
  value = try(data.aws_db_instance.this[0].db_name, module.config.project_name)
}
output "db_username" {
  value = "app"
}
