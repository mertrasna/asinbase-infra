# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands

Each environment is self-contained. Always `cd` into the environment before running Terraform.

```bash
cd environments/dev   # or environments/prod

terraform init        # first time, or after provider/backend changes
terraform validate    # check syntax
terraform fmt -check  # check formatting (use -diff to see changes)
terraform fmt         # auto-format
terraform plan        # preview changes
terraform apply       # apply changes
```

Bootstrap (one-time, already done):
```bash
cd bootstrap
terraform init && terraform apply
```

## Architecture

### Environment Layout

Two live environments (`dev`, `prod`) that share a common base (VPC, EC2, IAM role, CloudWatch log group, SSM-into-`.env` boot) but have **diverged** in shape. `staging/` is a placeholder with no Terraform code (`staging/info.txt` only).

The environments are **not** identical anymore:
- **Dev** adds WireGuard VPN ingress and the Night-Down stop/start Lambda. Single public subnet, instance type `var.instance_type` (default `t3.small`), 20 GB EBS that **is** deleted on termination, `hashicorp/archive` provider for the Lambda zip.
- **Prod** adds a public-facing stack: ALB + ACM certificate + WAFv2. Two public subnets across AZs `a`/`b` (an ALB requires ≥2 AZs), instance type hardcoded `t3.medium`, 30 GB EBS that is **not** deleted on termination.

Each environment is fully independent — separate VPC, EC2, IAM role, CloudWatch log group, and S3 state key. There are no shared modules; code is intentionally duplicated to keep environments independently manageable.

Remote state is stored in S3 (`asinbase-tfstate-eu-central-1-d2d3980f`) with state locking via `use_lockfile = true`.

### AMI Strategy

**Both** dev and prod pin the AMI via `var.ami_id` (same hardcoded default `ami-018f28221ffaa9b3b`, Ubuntu 24.04 LTS Noble amd64, in each env's `variables.tf`). The `data.aws_ami.ubuntu` block exists in both `ec2.tf` files for reference but is **not** wired into the instance — `aws_instance` reads `var.ami_id`, not the data source. To bump deliberately, run `terraform console` → `data.aws_ami.ubuntu.id` to get the latest ID, then update the `ami_id` default.

(Note: the `ami_id` variable description in `variables.tf` references `data.aws_ami.ubuntu_latest.id`, but the actual data source is named `data.aws_ami.ubuntu` — the `_latest` suffix is stale.)

### SSH Key Requirement

`terraform plan/apply` requires the SSH public key to exist locally:
- Dev: `~/.ssh/dev-ec2-key.pub`
- Prod: `~/.ssh/prod-ec2-key.pub`

If the file is missing, generate it from the private key: `ssh-keygen -y -f ~/.ssh/dev-ec2-key > ~/.ssh/dev-ec2-key.pub`

### user_data Behavior

Both environments have `user_data_replace_on_change = true`. Any edit to `user_data.sh` will **destroy and recreate the EC2 instance** on the next `terraform apply`. This is intentional for dev but high-risk for prod — always plan carefully before touching prod's `user_data.sh`.

`user_data.sh` fetches SSM parameters at boot into `/opt/myapp/.env`. SSM paths:
- Dev: `/dev/backend/*`
- Prod: `/prod/backend/*` (**known bug**: prod's `user_data.sh` currently fetches from `/dev/backend/` — the IAM policy denies it so `.env` is written empty. A manual `refresh_env` script on the instance corrects this at runtime.)

### Prod Public Stack: ALB + ACM + WAF (Prod Only)

Prod is reached through a public **Application Load Balancer**, not directly. Dev has none of this (it is VPN-gated).

**Traffic path:** Internet → ALB (WAF attached) → EC2 on port 80.

- **ALB** (`environments/prod/alb.tf`): internet-facing, across both public subnets. `enable_deletion_protection = true`, `idle_timeout = 60`. Two listeners — `:80` 301-redirects to `:443`; `:443` (TLS 1.3 policy `ELBSecurityPolicy-TLS13-1-2-2021-06`) forwards to the target group. **TLS terminates at the ALB**; the EC2 instance only serves plain HTTP on 80.
  - Target group health check: `GET /health` on the traffic port, expects `200`, `interval=30`, `timeout=5`, healthy/unhealthy thresholds 2/3, `deregistration_delay=30`.
  - If you raise `idle_timeout`, raise the instance's nginx `proxy_read_timeout` / Gunicorn `--timeout` above it too, or long requests get cut / cause 502s.
- **Security groups** (`environments/prod/security.tf`): the **ALB SG** allows `0.0.0.0/0` on 80/443. The **EC2 web SG** allows port 80 **only from the ALB SG** (no public HTTP/HTTPS direct to the instance) plus SSH 22 from `0.0.0.0/0`. So prod web traffic must go through the ALB.
- **ACM** (`environments/prod/acm.tf`): cert for `asinbase.com` + `*.asinbase.com`, **DNS validation**. DNS is managed in **Namecheap** (not Route 53), so validation/CNAME records are emitted as outputs (`acm_validation_records`, `alb_dns_name`, `alb_zone_id`) to copy in by hand. `aws_acm_certificate_validation` waits up to 30m.
- **WAF** (`environments/prod/waf.tf`): regional WAFv2 Web ACL associated with the ALB, default action `allow`. Rule modes currently differ from the original plan — **enforced (block)**: AmazonIpReputationList (p10), KnownBadInputs (p30), and the custom per-IP rate limit (p100, 2000 req / 5 min / IP). **Count/log-only (shakedown)**: CommonRuleSet (p20), SQLi (p40), LinuxRuleSet (p50). To enforce a Count rule, remove its `override_action { count {} }` so it falls back to the group's block action.
  - `environments/prod/waf-plan.md` is the **original design doc** and has drifted: it describes WAF logging (`aws-waf-logs-*` log group + `logging_configuration`) and `waf_*` outputs that are **not** implemented in `waf.tf`/`outputs.tf`. Treat `waf.tf` as the source of truth.

### WireGuard VPN (Dev Only)

Dev is intended to be VPN-gated. See `environments/dev/wireguard.md` for the full plan. Current state: WireGuard is installed and running, UDP 51820 is open in the security group, but SSH (port 22) is still open to `0.0.0.0/0` as a fallback. HTTP/HTTPS ingress rules are intentionally absent from dev's security group — access is via VPN IP `192.168.100.1`.

### Night-Down (Dev Only)

Dev's EC2 instance is **stopped at 00:00 and started at 08:00 (Europe/Berlin), every day** to cut compute cost outside working hours. The instance is only *stopped*, never terminated — the EBS volume, instance ID, and Elastic IP all persist, so the VPN/SSH endpoint stays stable across the cycle. Defined in `environments/dev/night_down.tf` + `environments/dev/lambda/night_down.py`.

Mechanism: two `aws_scheduler_schedule` (EventBridge Scheduler) resources invoke one Python Lambda. Each schedule passes `{"action": "stop"}` or `{"action": "start"}` as the event; the handler reads the instance from the `INSTANCE_ID` env var and calls the matching EC2 API. EventBridge Scheduler handles the Berlin timezone (incl. DST) natively — unlike the older UTC-only EventBridge Rules.

Two scoped IAM roles: the Lambda **execution role** can `ec2:Start/StopInstances` on *only* the dev instance; the **scheduler role** can `lambda:InvokeFunction` on *only* the night-down function. The Lambda has no Function URL / API Gateway — it is not internet-reachable.

This uses the `hashicorp/archive` provider (to zip the handler), declared in `backend.tf`. Run `terraform init` once after pulling this change to install it.

To change the window, edit the `schedule_expression` cron in `night_down.tf` (6-field format: `cron(min hour day-of-month month day-of-week year)`; use `?` for the unused day field). For weekdays only: `cron(0 0 ? * MON-FRI *)`.

### IAM Scoping

Each environment's IAM role is scoped to its own SSM path and CloudWatch log group — dev cannot read prod parameters and vice versa. The `AmazonSSMManagedInstanceCore` managed policy is attached to both, enabling SSM Session Manager as an alternative to SSH.
