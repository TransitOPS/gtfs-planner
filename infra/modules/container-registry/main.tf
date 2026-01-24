resource "aws_ecr_repository" "this" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"

  # TODO configure when the service is ready and disable the skip
  # checkov:skip=CKV_AWS_163:disabling scan_on_push for now
  # image_scanning_configauration {
  #   scan_on_push = true
  # }
  encryption_configuration {
    encryption_type = "KMS"
    # TODO create and use a KMS key
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [{
      description  = "No more than 100 images"
      rulePriority = 1
      selection = {
        countNumber = 100
        countType   = "imageCountMoreThan"
        tagStatus   = "any"
      }
      action = {
        type = "expire"
      }
    }]
  })
}
