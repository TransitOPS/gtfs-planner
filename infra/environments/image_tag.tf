# based on https://github.com/navapbc/template-infra/blob/main/infra/%7B%7Bapp_name%7D%7D/service/image_tag.tf

locals {
  config_file  = file("${path.module}/${var.name}.s3.tfbackend")
  config       = provider::terraform::decode_tfvars(local.config_file)
  state_bucket = local.config["bucket"]
  state_key    = local.config["key"]

  image_tag = (var.image_tag == null
    ? data.terraform_remote_state.image_tag[0].outputs.image_tag
  : var.image_tag)
}

data "terraform_remote_state" "image_tag" {
  # Don't do a lookup if image_tag is provided explicitly.
  # This saves some time and also allows us to do a first deploy,
  # where the tfstate file does not yet exist.
  count   = var.image_tag == null ? 1 : 0
  backend = "s3"

  config = {
    bucket = local.state_bucket
    key    = local.state_key
    region = module.config.default_region
  }

  defaults = {
    image_tag = null
  }
}

output "image_tag" {
  value = local.image_tag
}
