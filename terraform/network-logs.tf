resource "aws_cloudwatch_log_group" "vpc" {
  name              = "/parrilleros/vpc-flow"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.logs.arn
}

resource "aws_iam_role" "vpc_flow" {
  name = "parrilleros-vpc-flow-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow" {
  name = "write-vpc-flow-logs"
  role = aws_iam_role.vpc_flow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = [aws_cloudwatch_log_group.vpc.arn, "${aws_cloudwatch_log_group.vpc.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "*"
      }
    ]
  })
}

resource "aws_flow_log" "example" {
  vpc_id               = aws_vpc.example.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc.arn
  iam_role_arn         = aws_iam_role.vpc_flow.arn
  depends_on           = [aws_iam_role_policy.vpc_flow]
}
