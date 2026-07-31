# Private ECR registry for the two app images. Per D-048: images are built
# elsewhere and pushed here, never built on the EC2 host itself — the host
# is a t4g.small (2 vCPU / 2 GiB), `next build` on 2 GiB is a real OOM risk,
# and building on the host would mean the private ceiba-core-domain source
# and its checkout credentials would have to live on a production machine.
# Two ~93 MB images cost roughly $0.02/month in ECR storage.

resource "aws_ecr_repository" "runtime" {
  name = "ceiba-runtime"

  # A deployed tag must never silently change under a running host - that's
  # the entire point of "deployable from immutable build artifacts" (the
  # standing release gate this slice satisfies).
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "ceiba-runtime"
  }
}

resource "aws_ecr_repository" "control_plane" {
  name = "ceiba-control-plane"

  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "ceiba-control-plane"
  }
}

# Two 93 MB images with no expiry policy is how a $0.02/month line item
# quietly becomes a real one. Untagged images (superseded by a re-push, or
# left behind by a failed multi-arch manifest) expire after 1 day; only the
# most recent 10 tagged images are kept.
resource "aws_ecr_lifecycle_policy" "runtime" {
  repository = aws_ecr_repository.runtime.name
  policy     = data.aws_ecr_lifecycle_policy_document.standard.json
}

resource "aws_ecr_lifecycle_policy" "control_plane" {
  repository = aws_ecr_repository.control_plane.name
  policy     = data.aws_ecr_lifecycle_policy_document.standard.json
}

data "aws_ecr_lifecycle_policy_document" "standard" {
  rule {
    priority    = 1
    description = "Expire untagged images after 1 day"

    selection {
      tag_status   = "untagged"
      count_type   = "sinceImagePushed"
      count_unit   = "days"
      count_number = 1
    }
  }

  rule {
    priority    = 2
    description = "Keep only the most recent 10 tagged images"

    selection {
      tag_status       = "tagged"
      tag_pattern_list = ["*"]
      count_type       = "imageCountMoreThan"
      count_number     = 10
    }
  }
}
