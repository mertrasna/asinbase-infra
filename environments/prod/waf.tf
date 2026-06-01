resource "aws_wafv2_web_acl" "prod" {
  name  = "${local.name_prefix}-waf"
  scope = "REGIONAL" # REGIONAL = ALB/API Gateway. CLOUDFRONT would need us-east-1.

  default_action {
    allow {} # If no rule matches, allow the request through.
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-waf"
    sampled_requests_enabled   = true # Free sample of recent requests in console.
  }

  # ACL - access control list -
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 10 # Lower = evaluated first.

    override_action {
      none {} # Use the rule group's built-in actions (block).
      # Swap to `count {}` during shakedown to log-only.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 20

    override_action {
      count {} # Start in COUNT mode — high false-positive rate.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 30

    override_action {
      none {} # Low false-positive — safe to block from day one.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 40

    override_action {
      count {} # Can false-positive on apps that pass SQL-ish params.
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesLinuxRuleSet"
    priority = 50

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesLinuxRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesLinuxRuleSet"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 100

    action {
      block {} # Custom rules use `action`, not `override_action`.
    }

    statement {
      rate_based_statement {
        limit              = 2000 # Max requests per 5-minute window per IP.
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit-per-ip"
      sampled_requests_enabled   = true
    }
  }

  tags = {
    Name = "${local.name_prefix}-waf"
  }
}

resource "aws_wafv2_web_acl_association" "prod" {
  resource_arn = aws_lb.prod.arn
  web_acl_arn  = aws_wafv2_web_acl.prod.arn
}
