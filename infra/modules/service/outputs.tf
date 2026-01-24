output "task_network_configuration" {
  description = "--network-configuration value for running a task"
  value = {
    awsvpcConfiguration = {
      securityGroups = [var.db_external_sg_id, aws_security_group.this.id]
      subnets        = var.task_subnet_ids
      assignPublicIp = "DISABLED"
    }
  }
}
