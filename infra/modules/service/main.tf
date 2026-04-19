data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecs_service" "this" {
  name            = var.name
  cluster         = var.cluster_arn
  launch_type     = "FARGATE"
  desired_count   = coalesce(var.desired_count, 1)
  sigint_rollback = true
  #wait_for_steady_state = true

  task_definition = "${aws_ecs_task_definition.this.family}:${aws_ecs_task_definition.this.revision}"

  network_configuration {
    assign_public_ip = false
    security_groups  = [var.db_external_sg_id, aws_security_group.this.id]
    subnets          = var.task_subnet_ids
  }

  deployment_controller {
    type = "ECS"
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.lb.arn
    container_name   = local.container_name
    container_port   = local.container_port
  }

  depends_on = [aws_iam_role_policy.execution, aws_iam_role_policy.task]
}

data "aws_security_group" "external_db" {
  id = var.db_external_sg_id
}

resource "aws_security_group" "this" {
  name        = "service-${var.name}-service-sg"
  description = "Security group for the ${var.name} service"
  vpc_id      = data.aws_security_group.external_db.vpc_id
  tags = {
    Name = "service-${var.name}-service-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "task_from_lb" {
  security_group_id        = aws_security_group.this.id
  type                     = "ingress"
  description              = "Allow incoming requests from the load balancer"
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.lb.id
  from_port                = local.container_port
  to_port                  = local.container_port
}

resource "aws_security_group_rule" "task_to_world" {
  # checkov:skip=CKV_AWS_382:need to allow external access for fetching data
  security_group_id = aws_security_group.this.id
  type              = "egress"
  description       = "Allow egress to everywhere"
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
}

