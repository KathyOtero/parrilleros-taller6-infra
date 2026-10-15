terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Create a VPC
resource "aws_vpc" "example" {
  cidr_block = "10.0.0.0/16"
}


resource "aws_dynamodb_table" "name" {
  name         = "Empleados"
  hash_key     = "ID_empleado"
  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "ID_empleado"
    type = "S"
  }
}
