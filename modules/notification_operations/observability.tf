locals {
  telemetry        = jsondecode(file("${path.module}/operational-telemetry-v1.json"))
  metric_namespace = "Asinbase/Operations/${var.environment}"
  unit_map         = { count = "Count", seconds = "Seconds", tokens = "Count" }
  metric_groups = flatten([for metric, definition in local.telemetry.metrics : [
    for index, components in chunklist(sort([for component, metrics in local.telemetry.components : component if contains(metrics, metric)]), 8) : {
      key             = "${metric}-${index}"
      metric          = metric
      unit            = local.unit_map[definition.unit]
      raw_unit        = definition.unit
      component_match = join(" || ", [for component in components : "($.component = \"${component}\")"])
    }
  ]])
  metric_filters       = { for group in local.metric_groups : group.key => group }
  active_components    = var.enabled ? var.expected_components : toset([])
  queue_components     = toset([for component in local.active_components : component if contains(lookup(local.telemetry.components, component, []), "QueueOldestAgeSeconds") && !contains(keys(local.telemetry.email_age_thresholds_seconds), component)])
  failure_metrics      = toset(["CapabilityFailure", "CapabilityUnavailable", "WorkerIterationFailure", "TerminalErrors", "ExpiredLeases", "TruncatedWindows", "IncompleteWindows", "EmailDead", "EmailAmbiguous"])
  failure_alarms       = { for pair in flatten([for component in local.active_components : [for metric in lookup(local.telemetry.components, component, []) : { component = component, metric = metric } if contains(local.failure_metrics, metric)]]) : "${pair.component}-${pair.metric}" => pair }
  email_age_alarms     = { for alarm in flatten([for component, thresholds in local.telemetry.email_age_thresholds_seconds : [for severity, threshold in thresholds : { component = component, severity = severity, threshold = threshold }] if contains(local.active_components, component)]) : "${alarm.component}-${alarm.severity}" => alarm }
  heartbeat_components = { for component, seconds in local.telemetry.workers : component => { period = seconds > 86400 ? 3600 : (seconds >= 3600 ? 300 : 60), seconds = seconds } if contains(local.active_components, component) }
  actions              = var.alarm_actions_enabled ? var.alarm_topic_arns : toset([])
}
resource "terraform_data" "telemetry_contract" {
  count = var.enabled ? 1 : 0
  lifecycle {
    precondition {
      condition     = alltrue([for component in var.expected_components : contains(keys(local.telemetry.components), component)])
      error_message = "Expected components must belong to the versioned telemetry allowlist."
    }
    precondition {
      condition     = !anytrue([for component in var.expected_components : anytrue([for metric in lookup(local.telemetry.components, component, []) : contains(["QueuePending", "EmailAttemptsRollingHour", "ObservedDelivery", "InboxCreated", "ProviderBudgetDebt", "ProviderTokensRollingHour"], metric)])]) || contains(var.expected_components, "operational_metrics")
      error_message = "Expected durable aggregate metrics require the independently monitored operational_metrics producer."
    }
  }
}
resource "aws_cloudwatch_log_metric_filter" "operation" {
  for_each       = var.enabled ? local.metric_filters : {}
  name           = "${local.prefix}-${each.key}"
  log_group_name = var.log_group_name
  pattern        = "{ ($.event = \"${local.telemetry.event}\") && ($.environment = \"${local.application_environment}\") && ($.metric = \"${each.value.metric}\") && ($.unit = \"${each.value.raw_unit}\") && ($.value >= 0) && (${each.value.component_match}) }"
  metric_transformation {
    name       = each.value.metric
    namespace  = local.metric_namespace
    value      = "$.value"
    unit       = each.value.unit
    dimensions = { Component = "$.component" }
  }
  depends_on = [terraform_data.boundary]
  lifecycle {
    precondition {
      condition     = length("{ ($.event = \"${local.telemetry.event}\") && ($.environment = \"${local.application_environment}\") && ($.metric = \"${each.value.metric}\") && ($.unit = \"${each.value.raw_unit}\") && ($.value >= 0) && (${each.value.component_match}) }") <= 1024
      error_message = "CloudWatch filter must remain within its 1024-character limit."
    }
  }
}
resource "aws_cloudwatch_metric_alarm" "worker_missing" {
  for_each            = local.heartbeat_components
  alarm_name          = "${local.prefix}-${each.key}-missing-progress"
  alarm_description   = "No completed worker iteration within the accepted cadence; process/HTTP liveness is insufficient."
  namespace           = local.metric_namespace
  metric_name         = "WorkerHeartbeat"
  dimensions          = { Component = each.key }
  statistic           = "Sum"
  period              = each.value.period
  evaluation_periods  = ceil(each.value.seconds / each.value.period)
  datapoints_to_alarm = ceil(each.value.seconds / each.value.period)
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "operation_failure" {
  for_each            = local.failure_alarms
  alarm_name          = "${local.prefix}-${each.key}"
  alarm_description   = "Bounded ${each.value.metric} for accepted ${each.value.component}; inspect failure class without payloads."
  namespace           = local.metric_namespace
  metric_name         = each.value.metric
  dimensions          = { Component = each.value.component }
  statistic           = local.telemetry.metrics[each.value.metric].kind == "counter" ? "Sum" : "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each            = local.queue_components
  alarm_name          = "${local.prefix}-${each.key}-queue-age"
  alarm_description   = "Operational backlog age guard, not a product SLA. Original enqueue time survives retries."
  namespace           = local.metric_namespace
  metric_name         = "QueueOldestAgeSeconds"
  dimensions          = { Component = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.queue_age_alarm_seconds
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "queue_backlog" {
  for_each            = local.queue_components
  alarm_name          = "${local.prefix}-${each.key}-queue-backlog"
  alarm_description   = "Bounded operational queue volume guard; tune only after observed shadow demand."
  namespace           = local.metric_namespace
  metric_name         = "QueuePending"
  dimensions          = { Component = each.key }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.queue_backlog_alarm_count
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "email_age" {
  for_each            = local.email_age_alarms
  alarm_name          = "${local.prefix}-${each.key}-age"
  alarm_description   = "Agreed SMTP ${each.value.severity} backlog objective; internal capacity assumption, not an external delivery SLA."
  namespace           = local.metric_namespace
  metric_name         = "QueueOldestAgeSeconds"
  dimensions          = { Component = each.value.component }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  treat_missing_data  = "breaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "email_budget" {
  for_each            = { for component, ceiling in local.telemetry.email_attempt_ceiling : component => ceiling if contains(local.active_components, component) }
  alarm_name          = "${local.prefix}-${each.key}-hourly-budget"
  alarm_description   = "Shared rolling mailbox attempt allocation reached; include Auth and all other consumers before activation."
  namespace           = local.metric_namespace
  metric_name         = "EmailAttemptsRollingHour"
  dimensions          = { Component = each.key }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value
  treat_missing_data  = "breaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
locals {
  queue_native_alarms = {
    oldest  = { metric = "ApproximateAgeOfOldestMessage", queue = "ingress", threshold = var.queue_age_alarm_seconds, statistic = "Maximum" }
    backlog = { metric = "ApproximateNumberOfMessagesVisible", queue = "ingress", threshold = var.queue_backlog_alarm_count, statistic = "Maximum" }
    dlq     = { metric = "ApproximateNumberOfMessagesVisible", queue = "dlq", threshold = 1, statistic = "Maximum" }
  }
}
resource "aws_cloudwatch_metric_alarm" "sqs" {
  for_each            = var.enabled ? local.queue_native_alarms : {}
  alarm_name          = "${local.prefix}-sqs-${each.key}"
  namespace           = "AWS/SQS"
  metric_name         = each.value.metric
  dimensions          = { QueueName = "${local.prefix}-${each.value.queue}" }
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
resource "aws_cloudwatch_metric_alarm" "eventbridge_failure" {
  for_each            = var.enabled ? local.event_types : toset([])
  alarm_name          = "${local.prefix}-${lower(replace(each.key, "_", "-"))}-failed-invocation"
  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  dimensions          = { EventBusName = aws_cloudwatch_event_bus.partner[0].name, RuleName = aws_cloudwatch_event_rule.listing[each.key].name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}

locals {
  pressure_thresholds = {
    ProviderThrottle          = 5
    ProviderAdmissionDenied   = 5
    ProviderBudgetDebt        = 1
    IncrementalSyncAgeSeconds = 86400
  }
  pressure_alarms = { for pair in flatten([for component in local.active_components : [for metric in lookup(local.telemetry.components, component, []) : { component = component, metric = metric } if contains(keys(local.pressure_thresholds), metric)]]) : "${pair.component}-${pair.metric}" => pair }
}
resource "aws_cloudwatch_metric_alarm" "sustained_pressure" {
  for_each            = local.pressure_alarms
  alarm_name          = "${local.prefix}-${each.key}-sustained"
  alarm_description   = "Repeated capacity/freshness pressure; thresholds are operational guards, not provider promises."
  namespace           = local.metric_namespace
  metric_name         = each.value.metric
  dimensions          = { Component = each.value.component }
  statistic           = local.telemetry.metrics[each.value.metric].kind == "counter" ? "Sum" : "Maximum"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = local.pressure_thresholds[each.value.metric]
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.alarm_actions_enabled
  alarm_actions       = local.actions
  ok_actions          = local.actions
  tags                = local.tags
}
