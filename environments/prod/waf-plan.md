d## Adding AWS WAF to Prod ALB

This doc outlines adding an AWS WAFv2 Web ACL in front of the prod ALB ([environments/prod/alb.tf](environments/prod/alb.tf)).

### Scope

- Regional WAFv2 Web ACL (eu-central-1), associated with `aws_lb.prod`.
- Dev is VPN-gated and has no ALB, so WAF is prod-only.

### Pros

- **Managed rule coverage out of the box** — AWS Managed Rules (Common Rule Set, Known Bad Inputs, SQLi, Linux/Unix, IP reputation, anonymous IP list) cover OWASP-style attacks without writing signatures.
- **Layer 7 protection at the edge of the ALB** — blocks requests before they reach EC2, reducing load and blast radius of bad traffic.
- **Rate limiting** — per-IP request throttling protects `/login`, `/api/*`, etc. from brute force and scraping.
- **Geo / IP allow- or block-lists** — easy to restrict admin paths or block high-abuse regions.
- **Bot Control & ATP (optional, paid)** — token-based bot detection and credential-stuffing protection if needed later.
- **Visibility** — CloudWatch metrics per rule, sampled requests, and optional full request logging to S3/CloudWatch/Kinesis Firehose.
- **Terraform-native** — `aws_wafv2_web_acl` + `aws_wafv2_web_acl_association` is a clean, declarative addition; no infra refactor needed.

### Cons

- **Cost** — base: $5/Web ACL/month + $1/rule/month + $0.60 per million requests. Managed rule groups are free in count but each counts as a rule. Logging to CloudWatch/S3 adds storage cost. Realistic baseline: ~$15–30/month with a handful of managed rule groups, before traffic.
- **False positives** — Managed Core Rule Set frequently blocks legitimate traffic (large JSON bodies, admin endpoints, file uploads). Requires a `Count`-mode shakedown period before flipping to `Block`.
- **Operational overhead** — someone has to review CloudWatch metrics / sampled requests, tune exclusions, and respond to rule-group version bumps from AWS.
- **Request body inspection limits** — default 8 KB body inspection on ALB (configurable up to 64 KB, extra cost). Large payloads may slip past body rules.
- **Not a DDoS shield** — WAF mitigates L7 floods via rate-based rules but is not a substitute for Shield Advanced for volumetric L3/L4 attacks.
- **Latency** — small (single-digit ms) but non-zero added per request.
- **Region pinning** — Regional WAF is bound to eu-central-1; if the ALB ever moves regions, the ACL must be recreated there.

### Implementation Plan

#### 1. New file: `environments/prod/waf.tf`

Resources:

- `aws_wafv2_web_acl.prod` — scope `REGIONAL`, default action `allow`, with these rules (start every managed group in `Count` mode via `override_action { count {} }`):
  - `AWSManagedRulesCommonRuleSet` (priority 10)
  - `AWSManagedRulesKnownBadInputsRuleSet` (priority 20)
  - `AWSManagedRulesAmazonIpReputationList` (priority 30)
  - `AWSManagedRulesSQLiRuleSet` (priority 40)
  - `AWSManagedRulesLinuxRuleSet` (priority 50) — EC2 is Ubuntu
  - Custom `rate-limit-per-ip` rule (priority 100), `rate_based_statement` at e.g. 2000 req / 5min / IP, action `block`.
- `aws_wafv2_web_acl_association.prod` — associates the ACL with `aws_lb.prod.arn`.
- `aws_cloudwatch_log_group.waf` — name must start with `aws-waf-logs-`, retention 30 days.
- `aws_wafv2_web_acl_logging_configuration.prod` — sends to the log group; add a `redacted_fields` block for `authorization` and `cookie` headers.
- `visibility_config` on the ACL and every rule with `cloudwatch_metrics_enabled = true`.

#### 2. Outputs (`environments/prod/outputs.tf`)

- `waf_web_acl_arn`
- `waf_log_group_name`

#### 3. Rollout (two applies)

1. **Apply with all managed rules in `Count` mode + rate-limit in `Block`.** Let traffic flow ~3–7 days. Watch CloudWatch metrics + sampled requests for false positives on real traffic.
2. **Flip managed groups to `Block`** by removing `override_action { count {} }` per rule group, optionally adding `rule_action_override` entries for any specific sub-rules that produced false positives.

#### 4. Verification

- `terraform plan` shows only adds, no changes to ALB/EC2.
- After apply: hit a known-bad URL (e.g. `?q=<script>`) and confirm a `403` from WAF + a matching `BlockedRequests` metric.
- Confirm rate-limit by scripted burst from a single IP against a non-prod path.

#### 5. Things explicitly out of scope here

- Shield Advanced subscription.
- Bot Control / ATP managed rule groups (paid; add later if abuse warrants).
- Dev environment (no public ALB).
- CloudFront — there's no CF distribution in this stack today; if one is added later, WAF for it must be `scope = CLOUDFRONT` in `us-east-1` and is a separate ACL.

### Risk Notes

- ALB has `enable_deletion_protection = true` ([environments/prod/alb.tf:11](environments/prod/alb.tf#L11)) — the association does not touch the LB itself, so this is safe.
- WAF association is non-destructive: dissociating reverts traffic to pre-WAF behavior instantly. Easy rollback by removing `aws_wafv2_web_acl_association.prod`.
