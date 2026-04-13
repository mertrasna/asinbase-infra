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
  default     = "dev"
}

variable "developer_ip" {
  description = "Developer IP address in CIDR notation"  # Security groups require CIDR notation when you're specifying IP addresses.
  type = string
}