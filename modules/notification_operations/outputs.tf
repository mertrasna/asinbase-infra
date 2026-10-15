output "handoff" {
  description = "Nonsensitive operator handoff only; does not create SSM values or provider destinations/subscriptions."
  value = var.enabled ? {
    environment          = var.environment
    supabase_project_ref = var.supabase_project_ref
    queue_url            = aws_sqs_queue.ingress[0].url
    queue_arn            = aws_sqs_queue.ingress[0].arn
    dlq_arn              = aws_sqs_queue.dlq[0].arn
    event_bus_name       = aws_cloudwatch_event_bus.partner[0].name
    event_rule_state     = "DISABLED"
    application_id       = var.identities[var.environment].application_id
    ssm_prefix           = "/${var.environment}/backend/"
    proposed_parameters = {
      enable_worker_runtime                              = "false"
      enable_amazon_notification_worker                  = "false"
      enable_outbound_email                              = "false"
      enable_operational_telemetry                       = "false"
      enable_operational_metrics_worker                  = "false"
      sp_api_mutations_enabled                           = "false"
      amazon_notification_reconciliation_mode            = "observe"
      amazon_notification_sqs_queue_url                  = aws_sqs_queue.ingress[0].url
      amazon_notification_sqs_queue_arn                  = aws_sqs_queue.ingress[0].arn
      amazon_notification_sqs_wait_seconds               = "20"
      amazon_notification_sqs_visibility_timeout_seconds = "120"
      amazon_notification_application_id                 = var.identities[var.environment].application_id
      amazon_notification_sqs_destination_name           = "asinbase-${var.environment}-sqs"
      amazon_notification_eventbridge_destination_name   = "asinbase-${var.environment}-eventbridge"
    }
  } : null
}
