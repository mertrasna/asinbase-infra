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

variable "ami_id" {
  description = "AMI ID for the prod instance. Ubuntu 24.04 LTS (Noble) amd64. Update deliberately via `terraform console` -> data.aws_ami.ubuntu_latest.id"
  type        = string
  default     = "ami-018f28221ffaa9b3b"
}

variable "watchlist_threshold_alarm_email" {
  description = "Optional email subscribed to Watchlist threshold CloudWatch alarm notifications. The AWS subscription must be confirmed before delivery starts."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = (
      var.watchlist_threshold_alarm_email == null
      || can(regex("^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$", var.watchlist_threshold_alarm_email))
    )
    error_message = "watchlist_threshold_alarm_email must be null or a valid email address."
  }
}

variable "watchlist_threshold_min_fresh_coverage_pct" {
  description = "Minimum acceptable percentage of configured Watchlist threshold metrics backed by fresh canonical cache data. Tune after shadow telemetry."
  type        = number
  default     = 90

  validation {
    condition = (
      var.watchlist_threshold_min_fresh_coverage_pct >= 0
      && var.watchlist_threshold_min_fresh_coverage_pct <= 100
    )
    error_message = "watchlist_threshold_min_fresh_coverage_pct must be between 0 and 100."
  }
}
