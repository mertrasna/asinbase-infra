locals {
  account_id              = "254527609890"
  region                  = "eu-central-1"
  prefix                  = "asinbase-${var.environment}-amazon-notifications"
  expected_project_ref    = var.environment == "dev" ? "nehqpiqhdodkmyalpfpx" : "bbzowpqwdqamcrmwahch"
  application_environment = var.environment == "dev" ? "development" : "production"
  source_name             = try(var.identities[var.environment].partner_source_name, "")
  queue_arn               = "arn:aws:sqs:${local.region}:${local.account_id}:${local.prefix}-ingress"
  dlq_arn                 = "arn:aws:sqs:${local.region}:${local.account_id}:${local.prefix}-dlq"
  event_types             = toset(["LISTINGS_ITEM_STATUS_CHANGE", "LISTINGS_ITEM_ISSUES_CHANGE"])
  rule_arns               = [for kind in sort(tolist(local.event_types)) : "arn:aws:events:${local.region}:${local.account_id}:rule/${local.source_name}/${local.prefix}-${lower(replace(kind, "_", "-"))}"]
  runtime_actions         = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
  tags                    = { Environment = var.environment, Application = "asinbase", Activation = "held" }
}
data "aws_caller_identity" "current" { count = var.enabled ? 1 : 0 }
data "aws_region" "current" { count = var.enabled ? 1 : 0 }
resource "terraform_data" "boundary" {
  count = var.enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current[0].account_id == local.account_id && data.aws_region.current[0].region == local.region
      error_message = "Notification resources must target the approved AWS account and eu-central-1."
    }
    precondition {
      condition     = var.supabase_project_ref == local.expected_project_ref && var.worker_role_name == "${var.environment}-ec2-role" && var.log_group_name == "/asinbase-backend/${var.environment}"
      error_message = "Database, runtime role and log group must belong to this exact environment."
    }
  }
}
resource "aws_sqs_queue" "dlq" {
  count                      = var.enabled ? 1 : 0
  name                       = "${local.prefix}-dlq"
  fifo_queue                 = false
  sqs_managed_sse_enabled    = true
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 120
  tags                       = local.tags
  depends_on                 = [terraform_data.boundary]
  lifecycle { prevent_destroy = true }
}
resource "aws_sqs_queue" "ingress" {
  count                      = var.enabled ? 1 : 0
  name                       = "${local.prefix}-ingress"
  fifo_queue                 = false
  sqs_managed_sse_enabled    = true
  message_retention_seconds  = 345600
  visibility_timeout_seconds = 120
  receive_wait_time_seconds  = 20
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.dlq[0].arn, maxReceiveCount = 5 })
  tags                       = local.tags
  depends_on                 = [terraform_data.boundary]
  lifecycle { prevent_destroy = true }
}
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  count                = var.enabled ? 1 : 0
  queue_url            = aws_sqs_queue.dlq[0].url
  redrive_allow_policy = jsonencode({ redrivePermission = "byQueue", sourceQueueArns = [aws_sqs_queue.ingress[0].arn] })
}
resource "aws_cloudwatch_event_bus" "partner" {
  count             = var.enabled ? 1 : 0
  name              = local.source_name
  event_source_name = local.source_name
  tags              = local.tags
  depends_on        = [terraform_data.boundary]
  lifecycle { prevent_destroy = true }
}
resource "aws_cloudwatch_event_rule" "listing" {
  for_each       = var.enabled ? local.event_types : toset([])
  name           = "${local.prefix}-${lower(replace(each.key, "_", "-"))}"
  event_bus_name = aws_cloudwatch_event_bus.partner[0].name
  description    = "Held ${var.environment} listing events; explicit activation review required."
  state          = "DISABLED"
  event_pattern  = jsonencode({ source = [local.source_name], "detail-type" = [each.key] })
  tags           = local.tags
}
resource "aws_cloudwatch_event_target" "ingress" {
  for_each       = var.enabled ? local.event_types : toset([])
  event_bus_name = aws_cloudwatch_event_bus.partner[0].name
  rule           = aws_cloudwatch_event_rule.listing[each.key].name
  target_id      = "${var.environment}-notification-ingress"
  arn            = aws_sqs_queue.ingress[0].arn
  dead_letter_config { arn = aws_sqs_queue.dlq[0].arn }
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 5
  }
  depends_on = [aws_sqs_queue_policy.ingress, aws_sqs_queue_policy.dlq]
}
resource "aws_sqs_queue_policy" "ingress" {
  count     = var.enabled ? 1 : 0
  queue_url = aws_sqs_queue.ingress[0].url
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AmazonDirectNotificationDelivery", Effect = "Allow", Principal = { AWS = "arn:aws:iam::437568002678:root" }, Action = ["sqs:SendMessage", "sqs:GetQueueAttributes"], Resource = local.queue_arn },
    { Sid = "ExactEnvironmentEventRules", Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sqs:SendMessage", Resource = local.queue_arn,
    Condition = { ArnEquals = { "aws:SourceArn" = local.rule_arns }, StringEquals = { "aws:SourceAccount" = local.account_id } } },
    { Sid = "RequireTLS", Effect = "Deny", Principal = "*", Action = ["sqs:SendMessage", "sqs:ReceiveMessage"], Resource = local.queue_arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}
resource "aws_sqs_queue_policy" "dlq" {
  count     = var.enabled ? 1 : 0
  queue_url = aws_sqs_queue.dlq[0].url
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "ExactEnvironmentFailedEventRules", Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sqs:SendMessage", Resource = local.dlq_arn,
    Condition = { ArnEquals = { "aws:SourceArn" = local.rule_arns }, StringEquals = { "aws:SourceAccount" = local.account_id } } },
    { Sid = "RequireTLS", Effect = "Deny", Principal = "*", Action = ["sqs:SendMessage", "sqs:ReceiveMessage"], Resource = local.dlq_arn, Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}
resource "aws_iam_role_policy" "runtime" {
  count      = var.enabled ? 1 : 0
  name       = "${local.prefix}-consume-only"
  role       = var.worker_role_name
  policy     = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = local.runtime_actions, Resource = local.queue_arn }] })
  depends_on = [terraform_data.boundary]
}
