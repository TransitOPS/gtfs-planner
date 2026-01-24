locals {
  # ideally this would be HTTP2, but ALB won't forward HTTP1.1 requests
  # to an HTTP2 target group
  lb_protocol_version = "HTTP1"
}

resource "aws_lb" "lb" {
  name                       = var.name
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.lb.id]
  subnets                    = var.lb_subnet_ids
  drop_invalid_header_fields = true

  # checkov:skip= CKV_AWS_150:deletion protection enabled for non-temporary LBs
  enable_deletion_protection = !var.is_temporary
  # checkov:skip=CKV2_AWS_28:TODO enable WAF
  # checkov:skip=CKV_AWS_91:TODO enable access logging
}

resource "aws_lb_target_group" "lb" {
  name             = "${var.name}-${local.lb_protocol_version}"
  protocol         = "HTTP"
  protocol_version = local.lb_protocol_version
  target_type      = "ip"
  port             = local.container_port
  vpc_id           = data.aws_security_group.external_db.vpc_id

  health_check {
    path              = "/health"
    matcher           = "200-399"
    interval          = 10
    healthy_threshold = 2
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "lb_http" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "lb_https" {
  load_balancer_arn = aws_lb.lb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lb.arn
  }
}

resource "aws_security_group" "lb" {
  name        = "service-${var.name}-lb-sg"
  description = "Security group for the load balancer"
  vpc_id      = data.aws_security_group.external_db.vpc_id

  tags = {
    Name = "service-${var.name}-lb-sg"
  }

  ingress {
    description = "Allow HTTP"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
    # checkov:skip=CKV_AWS_260:we're explicitly allowing port 80 to redirect over to 443
  }

  ingress {
    description = "Allow HTTPS"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "Allow connection to the tasks"
    protocol        = "tcp"
    security_groups = [aws_security_group.this.id]
    from_port       = local.container_port
    to_port         = local.container_port
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "lb" {
  zone_id = var.hosted_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_lb.lb.dns_name
    zone_id                = aws_lb.lb.zone_id
    evaluate_target_health = false # TODO make true
  }
}
