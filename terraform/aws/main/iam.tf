resource "aws_iam_user" "pipeline" {
  name = "uk-property-pipeline"
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    sid    = "ListRawBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]

    resources = [
      aws_s3_bucket.raw.arn
    ]
  }
  statement {
    sid    = "ReadWriteRawObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "${aws_s3_bucket.raw.arn}/*"
    ]
  }
}

resource "aws_iam_user_policy" "pipeline_raw" {
  name   = "raw-bucket-access"
  user   = aws_iam_user.pipeline.name
  policy = data.aws_iam_policy_document.pipeline.json
}

# Terraform is the only source of truth for this user's permissions.
# Any managed policy attached by hand (e.g. AdministratorAccess) shows up
# in `terraform plan` and is removed on the next apply.
resource "aws_iam_user_policy_attachments_exclusive" "pipeline" {
  user_name   = aws_iam_user.pipeline.name
  policy_arns = []
}

# Likewise, the only inline policy allowed is the one defined above.
resource "aws_iam_user_policies_exclusive" "pipeline" {
  user_name    = aws_iam_user.pipeline.name
  policy_names = [aws_iam_user_policy.pipeline_raw.name]
}