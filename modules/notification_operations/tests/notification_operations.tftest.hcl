# Every test uses a mocked AWS provider: no credentials, cloud reads, apply or external state.
mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "254527609890" } }
  mock_data "aws_region" { defaults = { region = "eu-central-1", name = "eu-central-1" } }
}
variables {
  environment          = "dev"
  supabase_project_ref = "nehqpiqhdodkmyalpfpx"
  worker_role_name     = "dev-ec2-role"
  log_group_name       = "/asinbase-backend/dev"
  identities = {
    dev  = { application_id = "amzn1.sellerapps.app.dev-fixture", partner_source_name = "aws.partner/sellingpartnerapi.amazon.com/254527609890/amzn1.sellerapps.app.dev-fixture" }
    prod = { application_id = "amzn1.sellerapps.app.prod-fixture", partner_source_name = "aws.partner/sellingpartnerapi.amazon.com/254527609890/amzn1.sellerapps.app.prod-fixture" }
  }
}
run "disabled_is_empty" {
  command = plan
  assert {
    condition     = length(aws_sqs_queue.ingress) == 0 && length(aws_sqs_queue.dlq) == 0 && length(aws_cloudwatch_event_bus.partner) == 0 && length(aws_iam_role_policy.runtime) == 0 && output.handoff == null
    error_message = "Default module must create no queue, bus, runtime permissions or handoff."
  }
}
run "dev_isolated_and_held" {
  command = plan
  variables { enabled = true }
  assert {
    condition     = aws_sqs_queue.ingress[0].name == "asinbase-dev-amazon-notifications-ingress" && !aws_sqs_queue.ingress[0].fifo_queue && aws_sqs_queue.ingress[0].sqs_managed_sse_enabled && aws_sqs_queue.ingress[0].visibility_timeout_seconds == 120 && aws_sqs_queue.dlq[0].message_retention_seconds > aws_sqs_queue.ingress[0].message_retention_seconds
    error_message = "Queues must be separate, standard, encrypted, bounded and retain failures longer."
  }
  assert {
    condition     = alltrue([for rule in aws_cloudwatch_event_rule.listing : rule.state == "DISABLED" && jsondecode(rule.event_pattern).source == [var.identities.dev.partner_source_name]])
    error_message = "Rules must stay disabled and match exactly the dev source."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.runtime[0].policy).Statement[0].Resource == "arn:aws:sqs:eu-central-1:254527609890:asinbase-dev-amazon-notifications-ingress" && toset(jsondecode(aws_iam_role_policy.runtime[0].policy).Statement[0].Action) == toset(["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"])
    error_message = "Runtime policy must grant only exact ingress consumption, never wildcard/admin/purge/DLQ access."
  }
  assert {
    condition     = alltrue([for rule in aws_cloudwatch_event_target.ingress : rule.retry_policy[0].maximum_retry_attempts == 5 && rule.retry_policy[0].maximum_event_age_in_seconds == 3600])
    error_message = "Event delivery retries must remain bounded."
  }
  assert {
    condition     = output.handoff.proposed_parameters.enable_worker_runtime == "false" && output.handoff.proposed_parameters.enable_outbound_email == "false" && output.handoff.proposed_parameters.sp_api_mutations_enabled == "false" && output.handoff.proposed_parameters.amazon_notification_reconciliation_mode == "observe"
    error_message = "Infrastructure provisioning cannot activate application/provider/email behavior."
  }
}
run "prod_isolated_and_held" {
  command = plan
  variables {
    enabled              = true
    environment          = "prod"
    supabase_project_ref = "bbzowpqwdqamcrmwahch"
    worker_role_name     = "prod-ec2-role"
    log_group_name       = "/asinbase-backend/prod"
  }
  assert {
    condition     = aws_sqs_queue.ingress[0].name == "asinbase-prod-amazon-notifications-ingress" && aws_cloudwatch_event_bus.partner[0].event_source_name == var.identities.prod.partner_source_name && aws_iam_role_policy.runtime[0].role == "prod-ec2-role"
    error_message = "Production queue, bus, role and application identity must be separate from development."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_sqs_queue_policy.ingress[0].policy).Statement : statement.Resource == "arn:aws:sqs:eu-central-1:254527609890:asinbase-prod-amazon-notifications-ingress"]) && jsondecode(aws_sqs_queue_policy.ingress[0].policy).Statement[1].Condition.StringEquals["aws:SourceAccount"] == "254527609890" && alltrue([for arn in jsondecode(aws_sqs_queue_policy.ingress[0].policy).Statement[1].Condition.ArnEquals["aws:SourceArn"] : strcontains(arn, "prod-fixture/asinbase-prod-") && !strcontains(arn, "*")])
    error_message = "Publisher permissions must target only the exact production queue and rules."
  }
}
run "reject_cross_environment_database" {
  command = plan
  variables {
    enabled              = true
    supabase_project_ref = "bbzowpqwdqamcrmwahch"
  }
  expect_failures = [terraform_data.boundary]
}
run "reject_cross_environment_role" {
  command = plan
  variables {
    enabled          = true
    worker_role_name = "prod-ec2-role"
  }
  expect_failures = [terraform_data.boundary]
}
run "reject_cross_environment_logs" {
  command = plan
  variables {
    enabled        = true
    log_group_name = "/asinbase-backend/prod"
  }
  expect_failures = [terraform_data.boundary]
}
run "reject_missing_provider_identity" {
  command = plan
  variables {
    enabled    = true
    identities = {}
  }
  expect_failures = [var.identities]
}
run "reject_reused_application_and_source" {
  command = plan
  variables {
    enabled = true
    identities = {
      dev  = { application_id = "amzn1.sellerapps.app.shared", partner_source_name = "aws.partner/sellingpartnerapi.amazon.com/254527609890/amzn1.sellerapps.app.shared" }
      prod = { application_id = "amzn1.sellerapps.app.shared", partner_source_name = "aws.partner/sellingpartnerapi.amazon.com/254527609890/amzn1.sellerapps.app.shared" }
    }
  }
  expect_failures = [var.identities]
}
run "reject_cross_environment_alarm" {
  command = plan
  variables { alarm_topic_arns = ["arn:aws:sns:eu-central-1:254527609890:asinbase-prod-notifications"] }
  expect_failures = [var.alarm_topic_arns]
}
run "reject_wildcard_alarm" {
  command = plan
  variables { alarm_topic_arns = ["arn:aws:sns:eu-central-1:254527609890:asinbase-dev-*"] }
  expect_failures = [var.alarm_topic_arns]
}
run "reject_actions_without_destination" {
  command = plan
  variables {
    enabled               = true
    alarm_actions_enabled = true
  }
  expect_failures = [var.alarm_actions_enabled]
}
run "reject_wrong_account" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.aws_caller_identity.current[0]
    values = { account_id = "000000000000" }
  }
  expect_failures = [terraform_data.boundary]
}
run "reject_wrong_region" {
  command = plan
  variables { enabled = true }
  override_data {
    target = data.aws_region.current[0]
    values = { region = "us-east-1", name = "us-east-1" }
  }
  expect_failures = [terraform_data.boundary]
}

run "metrics_and_frozen_email_objectives" {
  command = plan
  variables {
    enabled             = true
    expected_components = ["operational_metrics", "daily_digest", "essential_email", "urgent_catalog_email", "routine_email", "email_total", "email_essential", "email_catalog", "email_other", "incremental_catalog", "keepa_global", "keepa_interactive"]
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.email_age["essential_email-warning"].threshold == 150 && aws_cloudwatch_metric_alarm.email_age["essential_email-alarm"].threshold == 300 && aws_cloudwatch_metric_alarm.email_age["urgent_catalog_email-alarm"].threshold == 3600 && aws_cloudwatch_metric_alarm.email_age["routine_email-alarm"].threshold == 86400
    error_message = "SMTP agreed age warning/objective thresholds must remain exact."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.email_budget["email_total"].threshold == 400 && aws_cloudwatch_metric_alarm.email_budget["email_essential"].threshold == 100 && aws_cloudwatch_metric_alarm.email_budget["email_catalog"].threshold == 250 && aws_cloudwatch_metric_alarm.email_budget["email_other"].threshold == 50
    error_message = "Mailbox total and non-lendable essential/catalog/other reservations must match the agreed budget."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.worker_missing["daily_digest"].period * aws_cloudwatch_metric_alarm.worker_missing["daily_digest"].evaluation_periods == 90000 && aws_cloudwatch_metric_alarm.worker_missing["operational_metrics"].period * aws_cloudwatch_metric_alarm.worker_missing["operational_metrics"].evaluation_periods == 300
    error_message = "Scheduled daily workers and frequent loops need their own accepted cadences."
  }
  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.operation) <= 80 && alltrue([for filter in aws_cloudwatch_log_metric_filter.operation : length(filter.pattern) <= 1024 && filter.metric_transformation[0].namespace == "Asinbase/Operations/dev" && length(filter.metric_transformation[0].dimensions) == 1 && filter.metric_transformation[0].dimensions["Component"] == "$.component" && strcontains(filter.pattern, "operational_metric_v1") && strcontains(filter.pattern, "development") && !strcontains(filter.pattern, "seller_id")])
    error_message = "Filters must remain bounded, environment-specific and free of identity dimensions."
  }
  assert {
    condition     = alltrue([for alarm in aws_cloudwatch_metric_alarm.email_age : !alarm.actions_enabled && length(alarm.alarm_actions) == 0]) && aws_cloudwatch_metric_alarm.operation_failure["essential_email-CapabilityUnavailable"].threshold == 1
    error_message = "Unavailable email capability must alarm explicitly only when expected; no notification actions may activate by default."
  }
}
run "no_worker_expectation_no_heartbeat_alarm" {
  command = plan
  variables { enabled = true }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.worker_missing) == 0 && length(aws_cloudwatch_metric_alarm.email_age) == 0 && length(aws_cloudwatch_metric_alarm.email_budget) == 0 && alltrue([for alarm in aws_cloudwatch_metric_alarm.sqs : !alarm.actions_enabled])
    error_message = "Held workers/email must not acquire expectations or alert actions just by creating infrastructure."
  }
}
run "reject_unbounded_component" {
  command = plan
  variables {
    enabled             = true
    expected_components = ["seller-secret-id"]
  }
  expect_failures = [terraform_data.telemetry_contract]
}

run "reject_aggregate_without_producer_heartbeat" {
  command = plan
  variables {
    enabled             = true
    expected_components = ["catalog_email"]
  }
  expect_failures = [terraform_data.telemetry_contract]
}
