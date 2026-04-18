variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-central-1" # frankfurt
}

variable "project_name" {
  description = "Short project identifier, used in resource naming and taging"
  type        = string
  default     = "asinbase"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}
