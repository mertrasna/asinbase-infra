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

Two live environments (`dev`, `prod`) with identical resource shapes but different configurations. `staging/` is a placeholder with no Terraform code.

Each environment is fully independent — separate VPC, EC2, IAM role, CloudWatch log group, and S3 state key. There are no shared modules; code is intentionally duplicated to keep environments independently manageable.

Remote state is stored in S3 (`asinbase-tfstate-eu-central-1-d2d3980f`) with state locking via `use_lockfile = true`.

### AMI Strategy

- **Dev** pins the AMI via `var.ami_id` (hardcoded default in `variables.tf`). The `data.aws_ami.ubuntu` block exists in `ec2.tf` for reference but is not used — run `terraform console` → `data.aws_ami.ubuntu.id` to get the latest ID when you want to update deliberately.
- **Prod** uses `data.aws_ami.ubuntu.id` directly, always resolving to the latest Ubuntu 24.04 LTS on apply.

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
