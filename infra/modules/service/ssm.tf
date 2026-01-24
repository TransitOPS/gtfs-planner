resource "aws_ssm_parameter" "secret_key_base" {
  name             = "${var.name}-SECRET_KEY_BASE"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.secret_key_base.result
  value_wo_version = 1

  # checkov:skip=CKV_AWS_337:TODO switch to KMS customer key
}

ephemeral "random_password" "secret_key_base" {
  length = 64
}
