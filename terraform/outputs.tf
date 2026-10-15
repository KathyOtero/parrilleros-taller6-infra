output "api_ecr_repository_url" {
  description = "Repositorio al que publicar la imagen revisada"
  value       = aws_ecr_repository.api.repository_url
}

output "api_cluster_name" {
  value = aws_ecs_cluster.api.name
}

output "api_service_name" {
  value = var.deploy_api ? aws_ecs_service.api[0].name : null
}

output "api_items_table" {
  value = aws_dynamodb_table.api_items.name
}

output "api_log_group" {
  value = aws_cloudwatch_log_group.api.name
}

output "api_status" {
  value = var.deploy_api ? "Servicio habilitado. Consultar la IP publica de la tarea ECS; acceso HTTP puerto 8080 solo desde el /32 autorizado." : "Preparacion: API desactivada. Publicar imagen en ECR antes de activar deploy_api."
}
