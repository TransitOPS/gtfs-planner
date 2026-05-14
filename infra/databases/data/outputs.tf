output "external_sg_id" {
  value = try(data.aws_security_group.external[0].id, null)
}
output "db_host" {
  value = try(data.aws_rds_cluster.this[0].endpoint, "${module.config.project_name}-database-${var.name}")
}
output "db_port" {
  value = try(data.aws_rds_cluster.this[0].port, 5432)
}
output "db_name" {
  value = try(data.aws_rds_cluster.this[0].database_name, local.database_config.postgres_database_name)
}
output "db_username" {
  value = "app"
}
