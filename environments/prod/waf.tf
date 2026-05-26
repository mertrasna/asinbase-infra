resource "aws_wafv2_web_acl" "prod" {
  name  = "${local.name_prefix}-waf"
  scope = "REGIONAL"  # REGIONAL = ALB/API Gateway. CLOUDFRONT would need us-east-1.

  default_action {
    allow {}  # If no rule matches, allow the request through.
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true  # Free sample of recent requests in console.
  }

  tags = {
    Name = "${local.name_prefix}-waf"
  }
}
