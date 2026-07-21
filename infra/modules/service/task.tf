
locals {
  container_name = "app"
  container_port = 4000
  environment = {
    PHX_SERVER       = true
    PHX_HOST         = var.domain
    PORT             = local.container_port
    MAIL_DOMAIN      = var.domain
    DATABASE_URL     = "ecto://${var.db_username}@${var.db_host}:${var.db_port}/${var.db_name}"
    DATABASE_USE_IAM = true
    OTP_JAR_PATH     = "/opt/otp/otp.jar"
    OTP_OSM_PATH     = "/opt/otp/data/philadelphia.osm.pbf"
    GTFS_TASK_ARTIFACTS_PATH            = "/app/var/gtfs-task-artifacts"
    GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES   = 157286400
    GTFS_TASK_ARTIFACTS_MAX_TOTAL_BYTES = 1073741824
    GTFS_TASK_ARTIFACTS_TTL_SECONDS     = 86400
    GEOAPIFY_API_KEY = var.geoapify_api_key
  }
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  network_mode             = "awsvpc"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = local.container_name
      image     = var.image_tag,
      essential = true,
      portMappings = [
        {
          containerPort = local.container_port,
          hostPort      = local.container_port,
          protocol      = "tcp"
      }],

      environment = [for k, v in local.environment :
      { name = k, value = tostring(v) }]
      secrets = [
        { name = "SECRET_KEY_BASE", valueFrom = aws_ssm_parameter.secret_key_base.arn }
      ]

      mountPoints = [
        {
          containerPath = "/app/lib/gtfs_planner-0.1.0/priv/static/uploads",
          sourceVolume  = "uploads"
        },
        {
          containerPath = "/app/var/gtfs-task-artifacts",
          sourceVolume  = "uploads"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.task.name,
          awslogs-region        = aws_cloudwatch_log_group.task.region,
          awslogs-stream-prefix = "ecs"
        }
      }

      healthCheck = {
        command  = ["CMD", "sh", "-c", "curl -fsS http://127.0.0.1:$PORT/health"]
        interval = 10
      }
    }
  ])

  volume {
    name = "uploads"

    s3files_volume_configuration {
      file_system_arn         = aws_s3files_file_system.uploads.arn
      root_directory          = "/"
      transit_encryption_port = local.efs_port
    }
  }

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "execution" {
  role   = aws_iam_role.execution.name
  policy = data.aws_iam_policy_document.execution.json
}

resource "aws_iam_role_policy" "task" {
  role   = aws_iam_role.task.name
  policy = data.aws_iam_policy_document.task.json
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "execution" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [aws_cloudwatch_log_group.task.arn
    , "${aws_cloudwatch_log_group.task.arn}:*"]
  }

  statement {
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]

    # checkov:skip=CKV_AWS_356:TODO figure out the right permissions here
  }

  statement {
    actions   = ["ssm:GetParameters"]
    resources = [aws_ssm_parameter.secret_key_base.arn]
  }
}

data "aws_iam_policy_document" "task" {
  statement {
    actions = [
      "rds-db:connect",
      "ses:SendEmail",
      "ses:SendRawEmail"
    ]
    resources = ["*"]
    # checkov:skip=CKV_AWS_356:TODO figure out the right permissions here
    # checkov:skip=CKV_AWS_109:need access to the DB credentials
    # checkov:skip=CKV_AWS_107:TODO limit access to the single DB
    # checkov:skip=CKV_AWS_111:TODO limit access to ??? for e-mail
  }

  statement {
    actions = [
      "s3files:ClientMount",
      "s3files:ClientWrite"
    ]
    resources = [aws_s3files_file_system.uploads.arn]
  }

  statement {
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion"
    ]
    resources = ["${aws_s3_bucket.uploads.arn}/*"]
  }

  statement {
    actions = [
      "s3:ListBucket"
    ]
    resources = [aws_s3_bucket.uploads.arn]
  }
}

resource "aws_cloudwatch_log_group" "task" {
  name = "/aws/ecs/${var.name}"
  # checkov:skip=CKV_AWS_338:not worrying about retaining debug logs
  retention_in_days = 30
  # checkov:skip=CKV_AWS_158:TODO not encrypting task logs for now
}
