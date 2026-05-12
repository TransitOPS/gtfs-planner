locals {
  lb_file                = ".compose-loadbalancer.yml"
  service_file           = ".compose-${var.project_name}-service-${var.name}.yml"
  service_name           = "${var.project_name}-service-${var.name}"
  service_uploads_volume = "${var.project_name}-service-${var.name}-uploads"
  lb_network             = "proxy"

  lb_content = yamlencode({
    services = {
      loadbalancer = {
        image   = "traefik:3"
        restart = "always"
        ports = [
          "80:80",
          "443:443"
        ]
        command = [
          "--providers.docker=true",
          "--providers.docker.exposedbydefault=false",
          "--providers.docker.network=ubuntu_${local.lb_network}",
          "--entryPoints.web.address=:80",
          "--entryPoints.web.http.redirections.entryPoint.to=websecure",
          "--entryPoints.web.http.redirections.entryPoint.scheme=https",
          "--entryPoints.web.http.redirections.entryPoint.permanent=true",
          "--entryPoints.websecure.address=:443",
          "--entryPoints.websecure.http.tls=true",
          "--certificatesresolvers.le.acme.email=postmaster@transitops.com",
          "--certificatesresolvers.le.acme.storage=/letsencrypt/acme.json",
          "--certificatesresolvers.le.acme.httpchallenge.entrypoint=web",
          "--log.level=INFO"
        ]
        networks = [
          local.lb_network
        ]
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock:ro",
          "./letsencript:/letsencrypt"
        ]
      }
    }
    networks = {
      "${local.lb_network}" = {}
    }
  })
  service_content = yamlencode({
    services = {
      "${local.service_name}" = {
        image   = var.image_tag
        restart = "always"
        environment = [
          "PORT=4000",
          "PHX_SERVER=true",
          "PHX_HOST=${var.domain}",
          "MAIL_DOMAIN=${var.domain}",
          "AWS_REGION=${data.aws_region.current.region}",
          "AWS_ACCESS_KEY_ID=${aws_iam_access_key.service.id}",
          "AWS_SECRET_ACCESS_KEY=${aws_iam_access_key.service.secret}",
          "SECRET_KEY_BASE=${random_password.secret_key_base.result}",
          "DATABASE_URL=ecto://${var.db_username}@${var.db_host}:${var.db_name}/${var.db_name}",
          "OTP_JAR_PATH=/opt/otp/otp.jar",
          "OTP_OSM_PATH=/opt/otp/data/philadelphia.osm.pbf",
          "GEOAPIFY_API_KEY=${var.geoapify_api_key}"
        ]
        networks = [
          local.lb_network,
          var.db_host
        ]
        volumes = [
          "${local.service_uploads_volume}:/app/lib/gtfs_planner-0.1.0/priv/static/uploads"
        ]
        labels = [
          "traefik.enable=true",
          "traefik.http.routers.${local.service_name}.rule=Host(`${var.domain}`)",
          "traefik.http.routers.${local.service_name}.tls.certresolver=le",
          "traefik.http.services.${local.service_name}.loadbalancer.server.port=4000",
          "traefik.docker.network=ubuntu_${local.lb_network}"
        ]
      }
    }
    volumes = {
      "${local.service_uploads_volume}" = {}
    }
    networks = {
      "${var.db_host}"      = {}
      "${local.lb_network}" = {}
    }
  })
}
resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "terraform_data" "service" {
  triggers_replace = [var.host, local.service_content]

  connection {
    type  = "ssh"
    user  = "ubuntu"
    host  = var.host
    agent = true
  }

  provisioner "file" {
    destination = local.service_file
    content     = local.service_content
  }

  provisioner "remote-exec" {
    inline = [
      # cheat by automatically migrating
      "docker compose -f ${local.service_file} run -e PHX_SERVER=false --rm ${var.project_name}-service-${var.name} eval 'GtfsPlanner.Release.migrate()'",
      "docker compose -f ${local.service_file} up -d --no-deps --quiet-pull --wait --wait-timeout 60"
    ]
  }
}

resource "terraform_data" "load_balancer" {
  triggers_replace = [var.host, local.lb_content]
  connection {
    type  = "ssh"
    user  = "ubuntu"
    host  = var.host
    agent = true
  }

  provisioner "file" {
    destination = local.lb_file
    content     = local.lb_content
  }

  provisioner "remote-exec" {
    inline = [
      "docker compose -f ${local.lb_file} up -d --no-deps --quiet-pull --wait --wait-timeout 60",
    ]
  }
}

data "aws_region" "current" {}

resource "aws_iam_user" "service" {
  name = local.service_name
  # checkov:skip=CKV_AWS_273:we limit this user to only the given IP address
}

resource "aws_iam_access_key" "service" {
  user = aws_iam_user.service.name
}

data "aws_iam_policy_document" "service" {
  statement {
    effect    = "Allow"
    actions   = ["ses:SendEmail", "ses:SendRawEmail"]
    resources = ["*"]
    # checkov:skip=CKV_AWS_111:SES is always against the * resource
  }

  statement {
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "NotIpAddress"
      variable = "aws:SourceIp"
      values   = ["${var.host}/32"]
    }

    condition {
      test     = "BoolIfExists"
      variable = "aws:ViaAWSService"
      values   = ["false"]
    }
  }
}

resource "aws_iam_user_policy" "service" {
  name   = local.service_name
  user   = aws_iam_user.service.name
  policy = data.aws_iam_policy_document.service.json
}
