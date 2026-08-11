output "instance_public_ip" {
  description = "Public IP (elastic) of the development server"
  value       = aws_eip.dev.public_ip
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/dev-ec2-key ubuntu@${aws_eip.dev.public_ip}"
}

output "watchlist_threshold_alarm_topic_arn" {
  description = "SNS topic used by Watchlist threshold CloudWatch alarms"
  value       = aws_sns_topic.watchlist_threshold_alarms.arn
}

output "watchlist_threshold_alarm_names" {
  description = "Watchlist threshold CloudWatch alarm names"
  value = {
    evaluation_missing = aws_cloudwatch_metric_alarm.watchlist_threshold_evaluation_missing.alarm_name
    oldest_pending     = aws_cloudwatch_metric_alarm.watchlist_threshold_oldest_pending.alarm_name
    delivery_failure   = aws_cloudwatch_metric_alarm.watchlist_threshold_delivery_health_failure.alarm_name
    dead_batch         = aws_cloudwatch_metric_alarm.watchlist_threshold_dead_batch.alarm_name
    fresh_coverage     = aws_cloudwatch_metric_alarm.watchlist_threshold_fresh_coverage.alarm_name
    trigger_volume     = aws_cloudwatch_metric_alarm.watchlist_threshold_trigger_volume.alarm_name
  }
}
