# Integrante 3. Reutiliza proveedor, region, VPC y clave KMS del integrante 1.
# Laboratorio: acceso HTTP a una tarea desde una IPv4 /32; sin ALB ni NAT.
# Para publicacion de produccion se requiere TLS y una entrada estable.

locals {
  compute_name = "${var.project_name}-${var.environment}"
  compute_tags = {
    Team        = "LOS PARRILLEROS"
    Project     = "parrilleros-taller6"
    Environment = var.environment
  }
}

data "aws_availability_zones" "compute" {
  state = "available"

  filter {
    name   = "zone-name"
    values = ["${var.aws_region}a"]
  }
}

resource "aws_ecr_repository" "api" {
  name                 = "${local.compute_name}-api"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.logs.arn
  }
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.compute_tags
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Eliminar capas sin tag despues de 7 dias"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}

# La API escribe id; Empleados exige ID_empleado. Se conserva Empleados intacta.
# Esta tabla adicional pertenece a esta pila y debe acordarse con integrante 1.
resource "aws_dynamodb_table" "api_items" {
  name         = "${local.compute_name}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.logs.arn
  }
  tags = local.compute_tags
}

resource "aws_internet_gateway" "api" {
  vpc_id = aws_vpc.example.id
  tags   = local.compute_tags
}

resource "aws_subnet" "api" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = data.aws_availability_zones.compute.names[0]
  map_public_ip_on_launch = false
  tags                    = local.compute_tags
}

resource "aws_route_table" "api" {
  vpc_id = aws_vpc.example.id
  tags   = local.compute_tags
}

resource "aws_route" "api_internet" {
  route_table_id         = aws_route_table.api.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.api.id
}

resource "aws_route_table_association" "api" {
  subnet_id      = aws_subnet.api.id
  route_table_id = aws_route_table.api.id
}

resource "aws_vpc_endpoint" "api_dynamodb" {
  vpc_id            = aws_vpc.example.id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.api.id]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = ["dynamodb:PutItem", "dynamodb:Scan"]
      Resource  = aws_dynamodb_table.api_items.arn
      Condition = { ArnEquals = { "aws:PrincipalArn" = aws_iam_role.api_task.arn } }
    }]
  })
  tags = local.compute_tags
}

resource "aws_security_group" "api" {
  name        = "${local.compute_name}-api"
  description = "API de laboratorio: una IPv4 autorizada y salida HTTPS"
  vpc_id      = aws_vpc.example.id
  ingress {
    description = "Demostracion desde una sola IPv4"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_client_cidr]
  }
  egress {
    description = "Servicios AWS por HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.compute_tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/parrilleros/api"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.logs.arn
  tags              = local.compute_tags
}

resource "aws_iam_role" "api_task" {
  name = "${local.compute_name}-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
  tags = local.compute_tags
}

resource "aws_iam_role_policy" "api_task" {
  name = "items-read-write"
  role = aws_iam_role.api_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.api_items.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.logs.arn
        Condition = {
          StringEquals = {
            "kms:ViaService"    = "dynamodb.${var.aws_region}.amazonaws.com"
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role" "api_execution" {
  name               = "${local.compute_name}-execution"
  assume_role_policy = aws_iam_role.api_task.assume_role_policy
  tags               = local.compute_tags
}

resource "aws_iam_role_policy" "api_execution" {
  name = "pull-image-and-write-logs"
  role = aws_iam_role.api_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = aws_ecr_repository.api.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.api.arn}:*"
      }
    ]
  })
}

resource "aws_ecs_cluster" "api" {
  name = local.compute_name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = local.compute_tags
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.compute_name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.api_execution.arn
  task_role_arn            = aws_iam_role.api_task.arn
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([{
    name                   = "api"
    image                  = "${aws_ecr_repository.api.repository_url}:${var.image_tag}"
    essential              = true
    user                   = "10001:10001"
    readonlyRootFilesystem = true
    privileged             = false
    linuxParameters        = { capabilities = { drop = ["ALL"] } }
    portMappings           = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "TABLE_NAME", value = aws_dynamodb_table.api_items.name },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "APP_VERSION", value = var.image_tag },
      { name = "LOG_LEVEL", value = "INFO" }
    ]
    healthCheck = {
      command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2)\" || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])
  tags = local.compute_tags
}

resource "aws_ecs_service" "api" {
  #checkov:skip=CKV_AWS_333:Demostracion dev sin NAT ni balanceador; IP publica necesaria para ECR. Entrada limitada a IPv4 /32. No es servicio publico de produccion.
  count                              = var.deploy_api ? 1 : 0
  name                               = "${local.compute_name}-api"
  cluster                            = aws_ecs_cluster.api.id
  task_definition                    = aws_ecs_task_definition.api.arn
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  wait_for_steady_state              = true
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE"
  network_configuration {
    subnets          = [aws_subnet.api.id]
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = true
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  lifecycle {
    precondition {
      condition     = var.image_tag != "bootstrap" && var.allowed_client_cidr != "127.0.0.1/32"
      error_message = "Para activar la API se requiere tag publicado y la IPv4 /32 real del equipo de pruebas."
    }
  }
  depends_on = [
    aws_iam_role_policy.api_task,
    aws_iam_role_policy.api_execution,
    aws_route.api_internet,
    aws_route_table_association.api,
    aws_vpc_endpoint.api_dynamodb
  ]
  tags = local.compute_tags
}
