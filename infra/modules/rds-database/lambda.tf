locals {
  python_version    = "3.13"
  db_admin_path     = "${path.module}/db_admin"
  db_admin_zip_path = "${local.db_admin_path}.zip"
  vendor_path       = "vendor"
}

resource "null_resource" "uv_install" {
  provisioner "local-exec" {
    command = "uv --directory ${local.db_admin_path} export --format requirements.txt | uv --directory ${local.db_admin_path} pip install -r - --target ${local.vendor_path} --python ${local.python_version}"
  }

  triggers = {
    index          = "${base64sha256(file("${local.db_admin_path}/pyproject.toml"))}"
    missing_vendor = fileexists("${local.db_admin_path}/vendor/six.py")
  }
}
resource "archive_file" "db_admin" {
  depends_on = [null_resource.uv_install]

  type             = "zip"
  source_dir       = local.db_admin_path
  output_file_mode = 0644
  output_path      = local.db_admin_zip_path

  excludes = [".venv", ".python-version", "pyproject.toml", "uv.lock"]

  lifecycle {
    replace_triggered_by = [null_resource.uv_install]
  }
}

resource "aws_lambda_function" "db_admin" {
  function_name                  = "db-admin-${var.name}"
  role                           = aws_iam_role.db_admin.arn
  architectures                  = ["arm64"]
  runtime                        = "python${local.python_version}"
  handler                        = "lambda_function.lambda_handler"
  filename                       = archive_file.db_admin.output_path
  source_code_hash               = archive_file.db_admin.output_base64sha256
  reserved_concurrent_executions = 1
  timeout                        = 3

  # checkov:skip=CKV_AWS_116:don't need a dead letter queue since we only execute this sync
  # checkov:skip=CKV_AWS_272:not worrying about code signing
  # checkov:skip=CKV_AWS_173:environment variables are not sensitive

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = [aws_security_group.external.id, aws_security_group.lambda.id]
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DB_HOST         = module.rds.db_instance_address,
      DB_PORT         = module.rds.db_instance_port,
      DB_NAME         = module.rds.db_instance_name,
      DB_PASSWORD_ARN = module.rds.db_instance_master_user_secret_arn,
      PYTHONPATH      = local.vendor_path,
    }
  }
}

resource "aws_iam_role" "db_admin" {
  name               = "db-admin-${var.name}"
  assume_role_policy = data.aws_iam_policy_document.db_admin_assume_role.json
}

data "aws_iam_policy_document" "db_admin_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

  }
}

resource "aws_iam_role_policy" "access" {
  role = aws_iam_role.db_admin.name
  name = "db-admin-access"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "secretsmanager:GetSecretValue"
        Effect   = "Allow"
        Resource = module.rds.db_instance_master_user_secret_arn
      },
      {
        Action   = "rds-db:connect"
        Effect   = "Allow"
        Resource = "*"
        # checkov:skip=CKV_AWS_287:TODO calculate the more specific ARN
        # checkov:skip=CKV_AWS_289:TODO calculate the more specific ARN
        # checkov:skip=CKV_AWS_355:TODO calculate the more specific ARN
      }
    ]
    }
  )
}

# Needed for putting a Lambda in a VPC
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.db_admin.name
  policy_arn = data.aws_iam_policy.vpc_access.arn
}

data "aws_iam_policy" "vpc_access" {
  name = "AWSLambdaVPCAccessExecutionRole"
}

resource "aws_cloudwatch_log_group" "db_admin" {
  name              = "/aws/lambda/${aws_lambda_function.db_admin.function_name}"
  retention_in_days = 1

  # checkov:skip=CKV_AWS_158:not worrying about encrypting debug logs
  # checkov:skip=CKV_AWS_338:not worrying about retaining debug logs
}

resource "aws_security_group" "lambda" {
  name        = "database-${var.name}-db-admin"
  description = "Security group for the db-admin-${var.name} Lambda"
  vpc_id      = data.aws_db_subnet_group.this.vpc_id

  tags = {
    Name = "database-${var.name}-db-admin"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "tls" {
  security_group_id = aws_security_group.lambda.id
  description       = "Provide external access to AWS Secrets Manager"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_database" {
  security_group_id = aws_security_group.lambda.id
  description       = "Provide access to the RDS database"

  referenced_security_group_id = aws_security_group.this.id
  ip_protocol                  = "tcp"
  from_port                    = module.rds.db_instance_port
  to_port                      = module.rds.db_instance_port
}
