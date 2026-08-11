data "aws_caller_identity" "current" {}

locals {
  watchlist_threshold_metric_namespace = "Asinbase/WatchlistThresholds/${var.environment}"
  watchlist_threshold_alarm_actions = (
    var.watchlist_threshold_alarm_email == null
    ? []
    : [aws_sns_topic.watchlist_threshold_alarms.arn]
  )
}

resource "aws_sns_topic" "watchlist_threshold_alarms" {
  name = "${local.name_prefix}-watchlist-threshold-alarms"
}

data "aws_iam_policy_document" "watchlist_threshold_alarm_topic" {
  statement {
    sid    = "AllowAccountManagement"
    effect = "Allow"
    actions = [
      "SNS:AddPermission",
      "SNS:DeleteTopic",
      "SNS:GetTopicAttributes",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
      "SNS:RemovePermission",
      "SNS:SetTopicAttributes",
      "SNS:Subscribe",
    ]
    resources = [
      aws_sns_topic.watchlist_threshold_alarms.arn,
    ]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid     = "AllowCloudWatchAlarmPublishing"
    effect  = "Allow"
    actions = ["SNS:Publish"]
    resources = [
      aws_sns_topic.watchlist_threshold_alarms.arn,
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:cloudwatch:${var.aws_region}:${data.aws_caller_identity.current.account_id}:alarm:${local.name_prefix}-watchlist-threshold-*",
      ]
    }
  }
}

resource "aws_sns_topic_policy" "watchlist_threshold_alarms" {
  arn    = aws_sns_topic.watchlist_threshold_alarms.arn
  policy = data.aws_iam_policy_document.watchlist_threshold_alarm_topic.json
}

resource "aws_sns_topic_subscription" "watchlist_threshold_alarm_email" {
  count = var.watchlist_threshold_alarm_email == null ? 0 : 1

  topic_arn = aws_sns_topic.watchlist_threshold_alarms.arn
  protocol  = "email"
  endpoint  = var.watchlist_threshold_alarm_email
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_evaluation_complete" {
  name           = "${local.name_prefix}-watchlist-threshold-evaluation-complete"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_evaluation_complete\") && ($.success = true) }"

  metric_transformation {
    name          = "EvaluationComplete"
    namespace     = local.watchlist_threshold_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_delivery_health" {
  name           = "${local.name_prefix}-watchlist-threshold-delivery-health"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_delivery_health\") && ($.success = true) }"

  metric_transformation {
    name          = "DeliveryHealthReport"
    namespace     = local.watchlist_threshold_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_delivery_health_failure" {
  name           = "${local.name_prefix}-watchlist-threshold-delivery-health-failure"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_delivery_health\") && ($.success = false) }"

  metric_transformation {
    name          = "DeliveryHealthFailure"
    namespace     = local.watchlist_threshold_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_oldest_pending_age" {
  name           = "${local.name_prefix}-watchlist-threshold-oldest-pending-age"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_delivery_health\") && ($.success = true) && ($.oldest_pending_age_seconds = *) }"

  metric_transformation {
    name      = "OldestPendingAgeSeconds"
    namespace = local.watchlist_threshold_metric_namespace
    value     = "$.oldest_pending_age_seconds"
    unit      = "Seconds"
  }
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_fresh_coverage" {
  name           = "${local.name_prefix}-watchlist-threshold-fresh-coverage"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_evaluation_complete\") && ($.success = true) && ($.fresh_cache_coverage_pct = *) }"

  metric_transformation {
    name      = "FreshCacheCoveragePct"
    namespace = local.watchlist_threshold_metric_namespace
    value     = "$.fresh_cache_coverage_pct"
    unit      = "Percent"
  }
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_dead_batch" {
  name           = "${local.name_prefix}-watchlist-threshold-dead-batch"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_dead_batch\") && ($.success = true) }"

  metric_transformation {
    name          = "DeadBatch"
    namespace     = local.watchlist_threshold_metric_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "watchlist_threshold_trigger_volume" {
  name           = "${local.name_prefix}-watchlist-threshold-trigger-volume"
  log_group_name = aws_cloudwatch_log_group.dev.name
  pattern        = "{ ($.event = \"watchlist_threshold_evaluation_complete\") && ($.success = true) && ($.trigger_volume = *) }"

  metric_transformation {
    name          = "TriggerVolume"
    namespace     = local.watchlist_threshold_metric_namespace
    value         = "$.trigger_volume"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "watchlist_threshold_evaluation_missing" {
  alarm_name          = "${local.name_prefix}-watchlist-threshold-missing-evaluation"
  alarm_description   = "No Watchlist threshold evaluation has completed for 26 consecutive hours."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 26
  datapoints_to_alarm = 26
  threshold           = 1
  metric_name         = "EvaluationComplete"
  namespace           = local.watchlist_threshold_metric_namespace
  period              = 3600
  statistic           = "Sum"
  unit                = "Count"
  treat_missing_data  = "breaching"
  actions_enabled     = var.watchlist_threshold_alarm_email != null
  alarm_actions       = local.watchlist_threshold_alarm_actions
  ok_actions          = local.watchlist_threshold_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "watchlist_threshold_oldest_pending" {
  alarm_name          = "${local.name_prefix}-watchlist-threshold-oldest-pending"
  alarm_description   = "The oldest pending Watchlist threshold alert is more than 24 hours old."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 86400
  metric_name         = "OldestPendingAgeSeconds"
  namespace           = local.watchlist_threshold_metric_namespace
  period              = 300
  statistic           = "Maximum"
  unit                = "Seconds"
  treat_missing_data  = "ignore"
  actions_enabled     = var.watchlist_threshold_alarm_email != null
  alarm_actions       = local.watchlist_threshold_alarm_actions
  ok_actions          = local.watchlist_threshold_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "watchlist_threshold_delivery_health_failure" {
  alarm_name          = "${local.name_prefix}-watchlist-threshold-delivery-health-failure"
  alarm_description   = "The Watchlist threshold worker could not read durable delivery-health gauges."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  metric_name         = "DeliveryHealthFailure"
  namespace           = local.watchlist_threshold_metric_namespace
  period              = 300
  statistic           = "Sum"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.watchlist_threshold_alarm_email != null
  alarm_actions       = local.watchlist_threshold_alarm_actions
  ok_actions          = local.watchlist_threshold_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "watchlist_threshold_dead_batch" {
  alarm_name          = "${local.name_prefix}-watchlist-threshold-dead-batch"
  alarm_description   = "A Watchlist threshold delivery batch reached the dead state."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  metric_name         = "DeadBatch"
  namespace           = local.watchlist_threshold_metric_namespace
  period              = 300
  statistic           = "Sum"
  unit                = "Count"
  treat_missing_data  = "notBreaching"
  actions_enabled     = var.watchlist_threshold_alarm_email != null
  alarm_actions       = local.watchlist_threshold_alarm_actions
  ok_actions          = local.watchlist_threshold_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "watchlist_threshold_fresh_coverage" {
  alarm_name          = "${local.name_prefix}-watchlist-threshold-fresh-coverage"
  alarm_description   = "Fresh canonical cache coverage is below the configured Watchlist threshold."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.watchlist_threshold_min_fresh_coverage_pct
  metric_name         = "FreshCacheCoveragePct"
  namespace           = local.watchlist_threshold_metric_namespace
  period              = 60
  statistic           = "Minimum"
  unit                = "Percent"
  treat_missing_data  = "ignore"
  actions_enabled     = var.watchlist_threshold_alarm_email != null
  alarm_actions       = local.watchlist_threshold_alarm_actions
  ok_actions          = local.watchlist_threshold_alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "watchlist_threshold_trigger_volume" {
  alarm_name          = "${local.name_prefix}-watchlist-threshold-trigger-volume"
  alarm_description   = "Watchlist threshold trigger volume is outside its recent hourly/daily baseline. The anomaly model can take up to two weeks to train."
  comparison_operator = "LessThanLowerOrGreaterThanUpperThreshold"
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold_metric_id = "trigger_volume_band"
  treat_missing_data  = "ignore"
  actions_enabled     = var.watchlist_threshold_alarm_email != null
  alarm_actions       = local.watchlist_threshold_alarm_actions
  ok_actions          = local.watchlist_threshold_alarm_actions

  metric_query {
    id          = "trigger_volume_band"
    expression  = "ANOMALY_DETECTION_BAND(trigger_volume, 2)"
    label       = "Trigger volume (expected)"
    return_data = false
  }

  metric_query {
    id          = "trigger_volume"
    return_data = true

    metric {
      metric_name = "TriggerVolume"
      namespace   = local.watchlist_threshold_metric_namespace
      period      = 3600
      stat        = "Sum"
      unit        = "Count"
    }
  }
}
