variable "project_name" {
  type        = string
  description = "Prefijo de los recursos del integrante 3"
  default     = "parrilleros"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.project_name))
    error_message = "Usar de 3 a 25 caracteres: minusculas, numeros y guiones."
  }
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = var.environment == "dev"
    error_message = "Esta configuracion de laboratorio solo admite dev."
  }
}

variable "deploy_api" {
  type        = bool
  description = "Activar solo despues de publicar y revisar la imagen en ECR"
  default     = false
}

variable "image_tag" {
  type        = string
  description = "Tag inmutable de la imagen revisada, preferiblemente SHA del commit"
  default     = "bootstrap"
  validation {
    condition     = can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", var.image_tag)) && var.image_tag != "latest"
    error_message = "Usar un tag Docker valido y distinto de latest."
  }
}

variable "allowed_client_cidr" {
  type        = string
  description = "IPv4 publica del equipo de demostracion con /32; no usar 0.0.0.0/0"
  default     = "127.0.0.1/32"
  validation {
    condition     = can(cidrnetmask(var.allowed_client_cidr)) && can(regex("/32$", var.allowed_client_cidr))
    error_message = "Usar una sola IPv4 en formato x.x.x.x/32."
  }
}
