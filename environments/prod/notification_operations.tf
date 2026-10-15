# Source-only by default. Enabling provisioning requires a separate reviewed plan/apply.
# Existing EC2/user_data, logs, IAM roles and provider settings are not modified.
variable "notification_operations_enabled" {
  type    = bool
  default = false
}
variable "notification_identities" {
  type    = map(object({ application_id = string, partner_source_name = string }))
  default = {}
}
variable "notification_expected_components" {
  type    = set(string)
  default = []
}
variable "notification_alarm_topic_arns" {
  type    = set(string)
  default = []
}
variable "notification_alarm_actions_enabled" {
  type    = bool
  default = false
}
module "notification_operations" {
  source                = "../../modules/notification_operations"
  enabled               = var.notification_operations_enabled
  environment           = "prod"
  supabase_project_ref  = "bbzowpqwdqamcrmwahch"
  worker_role_name      = aws_iam_role.ec2_prod.name
  log_group_name        = aws_cloudwatch_log_group.prod.name
  identities            = var.notification_identities
  expected_components   = var.notification_expected_components
  alarm_topic_arns      = var.notification_alarm_topic_arns
  alarm_actions_enabled = var.notification_alarm_actions_enabled
}
output "notification_operations_handoff" {
  value = module.notification_operations.handoff
}
