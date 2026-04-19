terraform {
  required_providers {
    env = {
      source  = "tcarreira/env"
      version = "0.2.0"
    }
  }
}
locals {
  project_name = "gtfs-planner"
  owner        = "transitops"
  # case-sensitive
  code_repository_url      = "https://github.com/TransitOPS/gtfs-planner"
  default_region           = "us-east-1"
  github_actions_role_name = "${local.project_name}-github-actions"

  accounts = {
    dev = {
      registry = {
        enable = true
      }
      cluster = {
        use_spot = false
      }
      hosted_zone = "gtfs-planner.transitops.tech"
      certificates = {
        "gtfs-planner.transitops.tech" = {}
      }
    }
  }

  networks = {
    dev = {
      account_name            = "dev"
      availability_zone_count = 2
      enable_nat_gateway      = false #true
      use_native_nat          = false
      hosted_zone             = "gtfs-planner.transitops.tech"
      certificates            = {}
    }
  }

  databases = {
    dev = {
      network_name = "dev"
      type         = "docker"
      host         = data.env_var.dev_ip.value
      is_temporary = true
    }
  }

  environments = {
    dev = {
      network_name     = "dev"
      database_name    = "dev"
      type             = "docker"
      host             = data.env_var.dev_ip.value
      domain           = "dev.gtfs-planner.transitops.tech"
      geoapify_api_key = data.env_var.geoapify_api_key.value
      is_temporary     = true
    }
  }
}

data "env_var" "dev_ip" {
  id = "DEV_IP"
}

data "env_var" "geoapify_api_key" {
  id = "GEOAPIFY_API_KEY"
}
