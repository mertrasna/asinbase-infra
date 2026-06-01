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

variable "ami_id" {
  description = "AMI ID for the dev instance. Ubuntu 24.04 LTS (Noble) amd64. Update deliberately via `terraform console` -> data.aws_ami.ubuntu_latest.id"
  type        = string
  default     = "ami-018f28221ffaa9b3b"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.small"
}
