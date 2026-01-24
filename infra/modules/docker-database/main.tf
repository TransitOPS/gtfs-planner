locals {
  docker_compose_file = ".compose-${var.project_name}-database-${var.name}.yml"
  service_name        = "${var.project_name}-database-${var.name}"
  network_name        = "${var.project_name}-database-${var.name}"
  volume_name         = "${var.project_name}-database-${var.name}"

  docker_compose_content = yamlencode({
    services = {
      "${local.service_name}" = {
        image   = "postgres:18.1"
        restart = "always"
        environment = [
          "POSTGRES_USER=app",
          "POSTGRES_HOST_AUTH_METHOD=trust",
          "POSTGRES_DB=${var.database_name}"
        ]
        volumes = [
          "${local.volume_name}:/var/lib/postgresql"
        ]
        networks = [
          "${local.network_name}"
        ]
      }
    }
    volumes = {
      "${local.volume_name}" = {}
    }
    networks = {
      "${local.network_name}" = {}
    }
  })
}
resource "terraform_data" "this" {
  triggers_replace = [var.host, local.docker_compose_content]

  connection {
    type  = "ssh"
    user  = "ubuntu"
    host  = var.host
    agent = true
  }

  provisioner "file" {
    destination = local.docker_compose_file
    content     = local.docker_compose_content
  }

  provisioner "remote-exec" {
    inline = [
      "docker compose -f ${local.docker_compose_file} up -d --no-deps --quiet-pull --wait --wait-timeout 60"
    ]
  }
}
