variable "aws_region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Team        = "LOS PARRILLEROS"
      Project     = "parrilleros-taller6"
      Environment = "dev"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_s3_bucket" "cloudtrail_logs" {
  #checkov:skip=CKV_AWS_144:Laboratorio dev de una region; no se implementa recuperacion entre regiones. Versionado habilitado. No equivale a DR de produccion.
  bucket = "empleados-cloudtrail-${data.aws_caller_identity.current.account_id}"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  bucket                  = aws_s3_bucket.cloudtrail_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  rule {
    id     = "limpiar-cargas-incompletas"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_notification" "cloudtrail_logs" {
  bucket      = aws_s3_bucket.cloudtrail_logs.id
  eventbridge = true
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  bucket = aws_s3_bucket.cloudtrail_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.cloudtrail_logs.arn, "${aws_s3_bucket.cloudtrail_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail_logs.arn
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail_logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/parrilleros/cloudtrail"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_iam_role" "cloudtrail_logs" {
  name = "parrilleros-cloudtrail-logs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name = "cloudtrail-write-logs"
  role = aws_iam_role.cloudtrail_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:log-stream:${data.aws_caller_identity.current.account_id}_CloudTrail_*"
    }]
  })
}

resource "aws_sns_topic" "cloudtrail" {
  name              = "parrilleros-cloudtrail"
  kms_master_key_id = aws_kms_key.notifications.arn
}

resource "aws_sns_topic_policy" "cloudtrail" {
  arn = aws_sns_topic.cloudtrail.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowOnlyThisTrail"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.cloudtrail.arn
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    }]
  })
}

resource "aws_cloudtrail" "empleados" {
  name                          = "empleados-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs.id
  enable_logging                = true
  enable_log_file_validation    = true
  include_global_service_events = true
  is_multi_region_trail         = true
  kms_key_id                    = aws_kms_key.logs.arn
  cloud_watch_logs_group_arn     = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn      = aws_iam_role.cloudtrail_logs.arn
  sns_topic_name                = aws_sns_topic.cloudtrail.name

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs,
    aws_s3_bucket_server_side_encryption_configuration.cloudtrail_logs,
    aws_iam_role_policy.cloudtrail_logs,
    aws_sns_topic_policy.cloudtrail
  ]

  event_selector {
    read_write_type           = "All"
    include_management_events = true
    data_resource {
      type   = "AWS::DynamoDB::Table"
      values = [aws_dynamodb_table.name.arn]
    }
  }
}
