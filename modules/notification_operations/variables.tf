variable "enabled" {
  description = "Provision reviewed infrastructure only. Does not enable any rule or application gate."
  type        = bool
  default     = false
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Only independent dev and prod environments are supported."
  }
}
variable "supabase_project_ref" {
  type        = string
  description = "Explicit environment database identity, verified against the fixed deployment map."
}
variable "worker_role_name" {
  type        = string
  description = "Existing environment EC2 runtime role; never an operator/admin role."
}
variable "log_group_name" {
  type = string
}
variable "identities" {
  description = "Operator-verified destination responses for BOTH environments; no credentials. Source names are supplied, never invented."
  type        = map(object({ application_id = string, partner_source_name = string }))
  default     = {}
  validation {
    condition = !var.enabled || try(
      toset(keys(var.identities)) == toset(["dev", "prod"]) &&
      var.identities.dev.application_id != var.identities.prod.application_id &&
      var.identities.dev.partner_source_name != var.identities.prod.partner_source_name &&
      alltrue([for identity in values(var.identities) :
        can(regex("^amzn1[.]sellerapps[.]app[.][A-Za-z0-9-]+$", identity.application_id)) &&
        identity.partner_source_name == "aws.partner/sellingpartnerapi.amazon.com/254527609890/${identity.application_id}"
    ]), false)
    error_message = "Enabled notification infrastructure requires distinct verified dev/prod application IDs and exact account/application-bound partner source names."
  }
}
variable "expected_components" {
  description = "Components separately accepted and enabled by operators. Empty preserves off gates and creates no application alarms."
  type        = set(string)
  default     = []
}
variable "alarm_topic_arns" {
  description = "Explicit environment-only SNS topic ARNs. No topic, subscription or recipient is created here."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.alarm_topic_arns : can(regex("^arn:aws:sns:eu-central-1:254527609890:asinbase-${var.environment}-[A-Za-z0-9_-]+$", arn))])
    error_message = "Alarm destinations must be exact SNS ARNs in this account, region and environment; wildcards/cross-environment destinations are forbidden."
  }
}
variable "alarm_actions_enabled" {
  description = "Independent opt-in after tested alarm routing. Defaults false even with provisioned queues."
  type        = bool
  default     = false
  validation {
    condition     = !var.alarm_actions_enabled || (var.enabled && length(var.alarm_topic_arns) > 0)
    error_message = "Alarm actions require provisioned infrastructure and explicit environment SNS destinations."
  }
}

variable "queue_age_alarm_seconds" {
  type        = number
  default     = 3600
  description = "Internal generic queue-age guard; not a claimed customer SLA. Email objectives use their separate frozen values."
  validation {
    condition     = var.queue_age_alarm_seconds >= 120 && var.queue_age_alarm_seconds <= 86400
    error_message = "Queue-age threshold must be between 120 seconds and one day."
  }
}
variable "queue_backlog_alarm_count" {
  type    = number
  default = 1000
  validation {
    condition     = var.queue_backlog_alarm_count >= 1 && var.queue_backlog_alarm_count <= 1000000 && floor(var.queue_backlog_alarm_count) == var.queue_backlog_alarm_count
    error_message = "Queue backlog threshold must be a bounded positive integer."
  }
}
