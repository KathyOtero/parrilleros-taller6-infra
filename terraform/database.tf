terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_vpc" "example" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_default_security_group" "example" {
  vpc_id = aws_vpc.example.id
  ingress = []
  egress  = []
}

resource "aws_dynamodb_table" "name" {
  name         = "Empleados"
  hash_key     = "ID_empleado"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "ID_empleado"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.logs.arn
  }
}
