data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tfbackend_file         = file("${path.module}/${var.name}.s3.tfbackend")
  tfbackend              = provider::terraform::decode_tfvars(local.tfbackend_file)
  tofu_state_bucket_name = local.tfbackend["bucket"]
  account_config         = module.config.accounts[var.name]
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6"
    }

    terraform = {
      source = "terraform.io/builtin/terraform"
    }
  }

  backend "s3" {
    use_lockfile = true
    encrypt      = true
  }
}
provider "aws" {
  region = module.config.default_region
  default_tags {
    tags = module.config.default_tags
  }
}

module "s3_backend" {
  source = "../modules/tofu-s3-backend"
  bucket = local.tofu_state_bucket_name
}

import {
  to = module.s3_backend.aws_s3_bucket.default
  id = local.tofu_state_bucket_name
}

module "container_registry" {
  source = "../modules/container-registry"

  name = module.config.project_name
}

module "cluster" {
  source = "../modules/ecs-cluster"

  name     = module.config.project_name
  use_spot = try(local.account_config.cluster.use_spot, false)
}

module "github_oidc" {
  source                   = "../modules/github-oidc"
  github_actions_role_name = module.config.github_actions_role_name
  github_repo              = module.config.github_repo

  permissions = [
    # https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-push-iam.html
    "ecr:BatchCheckLayerAvailability",
    "ecr:BatchGetImage",
    "ecr:CompleteLayerUpload",
    "ecr:GetAuthorizationToken",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart",
    # docker manifest inspect
    "ecr:GetDownloadUrlForLayer",
    # running Tofu
    "s3:DeleteObject",
    "s3:GetObject",
    "s3:HeadObject",
    "s3:PutObject",
    # deploying tasks
    "ec2:Describe*",
    "ecs:*",
    "elasticloadbalancing:Describe*",
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:GetUser",
    "iam:ListAccessKeys",
    "iam:List*RolePolicies",
    "iam:PassRole",
    "logs:DescribeLogGroups",
    "logs:FilterLogEvents",
    "logs:ListTagsForResource",
    "rds:Describe*",
    "ssm:DescribeParameters",
    "ssm:GetParameter*",
    "ssm:ListTagsForResource",
  ]
}

module "domain" {
  source = "../modules/domain"

  hosted_zone  = local.account_config.hosted_zone
  certificates = local.account_config.certificates
}

module "config" {
  source = "../config"
}

