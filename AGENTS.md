# AGENTS.md

This file guides AI agents and maintainers working on the Terraform in this repository. For the infrastructure contract relevant to backend and frontend development, read `APPLICATION_INFRASTRUCTURE.md`.

The Terraform and boot scripts are the source of truth. Update this guide whenever an infrastructure change invalidates it.

## Working rules

- `bootstrap/`, `environments/dev/`, and `environments/prod/` are separate Terraform roots. Always run Terraform inside the intended root or use `terraform -chdir=<root>`.
- Never apply or destroy live infrastructure unless the user explicitly requests it. Inspect a saved or displayed plan before any authorized apply.
- Treat dev and prod independently. Their code is intentionally duplicated and their topology has diverged; do not assume a change should be mirrored.
- Preserve unrelated user changes in the worktree.
- Keep credentials, secrets, real `*.tfvars`, state, and host-generated WireGuard keys out of Git.
- Prefer narrowly scoped IAM and security-group changes. Do not broaden access just to make a deployment work.
- Any edit to either `user_data.sh` replaces its EC2 instance because `user_data_replace_on_change = true`.
- Prod changes require extra care: its instance is the only ALB target, its root disk is retained but not automatically reattached after replacement, and the ALB has deletion protection.
- Treat `waf.tf` and `security.tf` as authoritative. The older `waf-plan.md` and `wireguard.md` contain known drift.

## Common commands

Each environment is self-contained:

```bash
terraform -chdir=environments/dev init
terraform -chdir=environments/dev fmt -check -diff
terraform -chdir=environments/dev validate
terraform -chdir=environments/dev plan

terraform -chdir=environments/prod init
terraform -chdir=environments/prod fmt -check -diff
terraform -chdir=environments/prod validate
terraform -chdir=environments/prod plan
```

Bootstrap was a one-time operation:

```bash
terraform -chdir=bootstrap init
terraform -chdir=bootstrap plan
```

Do not casually reapply or destroy bootstrap. It owns the remote-state bucket and uses local state.

Planning requires AWS credentials, S3 backend access, and the environment's SSH public key:

- dev: `~/.ssh/dev-ec2-key.pub`
- prod: `~/.ssh/prod-ec2-key.pub`

If the provider cache is missing or stale, run `terraform init` before `validate`. Commit lock-file changes only when provider selection was intentionally changed.

## Repository layout and state

```text
bootstrap/                 Creates the S3 remote-state bucket; local Terraform state
environments/dev/          Live dev environment
environments/prod/         Live production environment
environments/staging/      Placeholder only; no Terraform code
APPLICATION_INFRASTRUCTURE.md
                           App-facing contract for backend/frontend agents
```

The live environments use S3 backend bucket `asinbase-tfstate-eu-central-1-d2d3980f` with encryption and native S3 lock files:

- dev key: `environments/dev/terraform.tfstate`
- prod key: `environments/prod/terraform.tfstate`

Bootstrap creates a versioned, private S3 bucket with a random suffix and `prevent_destroy`. Because bootstrap has no backend block, its state remains local and is ignored by Git. Migrating or renaming the live backend requires an explicit state-migration plan.

Terraform requires `~> 1.10`; the AWS provider constraint is `~> 6.40`. Bootstrap additionally uses `hashicorp/random`; dev uses `hashicorp/archive` for the Night-Down Lambda package.

Both AWS provider blocks hardcode `eu-central-1`. `var.aws_region` is used to form availability-zone names but does not configure the provider. Do not change only that variable to move regions.

## Architecture summary

| Concern | Dev | Prod |
|---|---|---|
| VPC | `10.0.0.0/16` | `10.0.0.0/16` |
| Public subnets | One, `10.0.1.0/24`, AZ `a` | Two, `10.0.1.0/24` and `10.0.2.0/24`, AZs `a`/`b` |
| EC2 | `var.instance_type`, default `t3.small` | Hardcoded `t3.medium` |
| Root EBS | 20 GiB gp3, encrypted, deleted on termination | 30 GiB gp3, encrypted, retained on termination |
| Public address | Elastic IP, `prevent_destroy` | Elastic IP, `prevent_destroy` |
| Web entry | Direct EC2 ingress on 80/443 | WAF-protected ALB on 80/443 |
| SSH | Public on 22 | Public on 22 |
| Additional features | WireGuard ingress; nightly stop/start | ACM, ALB, WAF |
| App log group | 7-day retention | 14-day retention |

The VPCs are independent despite overlapping CIDRs. There is no peering, NAT gateway, or private subnet. Both EC2 instances are in public subnets with unrestricted outbound security-group traffic.

## File ownership

| File | Responsibility |
|---|---|
| `backend.tf` | Terraform/provider requirements and live S3 backend |
| `providers.tf` | AWS provider region and default tags |
| `variables.tf`, `locals.tf` | Inputs and resource-name prefix |
| `network.tf` | VPC, subnet(s), internet gateway, public route table |
| `security.tf` | Security groups and ingress/egress rules |
| `ec2.tf` | SSH key pair, AMI lookup, instance, disk, Elastic IP |
| `iam.tf` | EC2 role/profile, SSM access, log group and log permissions |
| `user_data.sh` | First-boot package installation and `.env` generation |
| `dev/night_down.tf` | Lambda package, roles, function, schedules |
| `dev/lambda/night_down.py` | EC2 start/stop handler |
| `dev/setup-wireguard.sh` | Manual WireGuard setup; Terraform does not execute it |
| `prod/acm.tf` | ACM certificate and validation waiter |
| `prod/alb.tf` | ALB, target group, listeners and apex redirect |
| `prod/waf.tf` | WAF rules and ALB association |
| `outputs.tf` | Connection details and external DNS handoff values |

There are no shared modules. Duplication is deliberate so each environment can evolve independently.

## AMI and EC2 lifecycle

Both environments pin `aws_instance.ami` to `var.ami_id`, currently `ami-018f28221ffaa9b3b` for Ubuntu 24.04 Noble amd64. `data.aws_ami.ubuntu` discovers the latest matching Canonical image but is not connected to the instance.

To update the AMI deliberately:

1. Initialize the environment.
2. Inspect `data.aws_ami.ubuntu.id`, for example through `terraform console`.
3. Update the pinned `ami_id` default or provide an explicit override.
4. Review the replacement plan and arrange application redeployment.

The variable descriptions incorrectly mention `data.aws_ami.ubuntu_latest.id`; the real data source is `data.aws_ami.ubuntu`.

Replacement effects:

- Dev loses its root disk, deployed app state, and manually generated WireGuard configuration.
- Prod leaves the old root volume behind but boots from a new volume; Terraform does not reattach the old one.
- Elastic IPs normally survive and re-associate, but their `prevent_destroy` blocks a full environment destroy.
- Terraform does not redeploy the application after instance replacement.

## Boot-time behavior

Both `user_data.sh` scripts:

1. Upgrade Ubuntu.
2. Install base tools, UFW, fail2ban, and unattended upgrades.
3. Install Docker Engine, Buildx, and Docker Compose from Docker's repository.
4. Configure Docker JSON-log rotation at 10 MiB with three files.
5. Install the x86_64 AWS CLI v2.
6. Install/start nginx and write a placeholder page.
7. Open OpenSSH and `Nginx Full` in UFW.
8. Create `/opt/myapp/.env` from SSM Parameter Store.

They do not deploy the application, configure nginx as an app reverse proxy, start containers, create the ALB `/health` response, or configure CloudWatch log shipping.

SSM parameters are flattened by basename and uppercased. Dev correctly requests `/dev/backend/`. Prod currently also requests `/dev/backend/`, but its IAM role permits only `/prod/*`; the failure is suppressed and usually produces `# No SSM params yet`. The intended prod path is `/prod/backend/`. Fixing it in user data replaces prod EC2, so plan the migration rather than applying the one-line change casually.

## Dev specifics

The current security group publicly exposes:

- TCP 22: SSH fallback
- TCP 80: HTTP, including external webhook access
- TCP 443: HTTPS, including external webhook access
- UDP 51820: WireGuard

All are open to `0.0.0.0/0`. Dev is not currently VPN-only, despite older documentation. The boot script does not provision a dev certificate or nginx TLS configuration; opening port 443 alone does not make HTTPS functional.

`setup-wireguard.sh` is manual host configuration. It creates `wg0` at `192.168.100.1/24`, generates server and peer keys, enables forwarding/NAT, opens UFW, and starts `wg-quick@wg0`. Generated keys and client configs exist only on the instance unless securely backed up.

Night-Down uses two EventBridge Scheduler resources and one Python 3.12 Lambda:

- stop at 00:00 Europe/Berlin every day;
- start at 08:00 Europe/Berlin every day.

The Lambda role can start/stop only the Terraform-managed dev instance. The scheduler role can invoke only that Lambda. Stopping preserves instance identity, root disk, and EIP. The schedule uses the Berlin timezone, so AWS handles DST.

`data.archive_file.night_down` generates `lambda/night_down.zip` from `night_down.py`. Edit the Python source rather than the zip. A plan may regenerate the committed zip; review the diff before committing it.

## Prod specifics

Traffic flows through the internet-facing ALB:

```text
Internet -> WAF-protected ALB -> HTTPS listener -> target group -> EC2 HTTP :80
```

- Port 80 on the ALB redirects to HTTPS.
- ACM terminates TLS for `asinbase.com` and `*.asinbase.com`.
- Requests with host `asinbase.com` redirect to `https://www.asinbase.com`.
- All other hosts and paths use the single default target group.
- The EC2 web security group permits port 80 only from the ALB security group.
- SSH remains public on port 22.
- ALB deletion protection is enabled; HTTP/2 is enabled; idle timeout is 60 seconds.

The target group contains one EC2 target. Its health check is HTTP `GET /health`, expects only `200`, runs every 30 seconds with a 5-second timeout, and uses thresholds 2 healthy / 3 unhealthy. Deregistration delay is 30 seconds. Fresh user data does not create `/health`, so application deployment is required before the target becomes healthy.

ACM uses DNS validation with a 30-minute create timeout. DNS is external, currently Namecheap; this repository creates no Route 53 records. Outputs expose the required validation records and ALB DNS name. Certificate and DNS changes can require manual coordination during apply.

### WAF source of truth

`environments/prod/waf.tf` currently defines:

| Priority | Rule | Mode |
|---:|---|---|
| 10 | Amazon IP Reputation | Enforced managed actions |
| 20 | Common Rule Set | Count only |
| 30 | Known Bad Inputs | Enforced managed actions |
| 40 | SQLi Rule Set | Count only |
| 50 | Linux Rule Set | Count only |
| 100 | 2,000 requests per 5 minutes per IP | Block |

The ACL defaults to allow. Metrics and sampled requests are enabled. Full WAF request logging, redaction configuration, WAF outputs, and the Anonymous IP managed group described in `waf-plan.md` are not implemented.

## IAM and observability

Each EC2 role has:

- `AmazonSSMManagedInstanceCore` for SSM managed-instance features;
- read access to only its environment's SSM path;
- write access to only its environment's application log group.

Log groups are `/asinbase-backend/dev` with 7-day retention and `/asinbase-backend/prod` with 14-day retention. No CloudWatch agent, Docker CloudWatch driver, or application log integration is configured, so creating the groups and permissions does not ship logs.

The Night-Down Lambda separately uses `AWSLambdaBasicExecutionRole` for its logs and a narrowly scoped EC2 start/stop policy.

## Pre-apply checklist

Before any explicitly authorized apply:

1. Confirm the Terraform root, workspace, AWS account, region, and caller identity.
2. Confirm backend initialization and the expected remote-state key.
3. Run `fmt -check` and `validate`.
4. Review every plan action, especially instance replacement, retained/deleted disks, IAM broadening, public ingress, ALB replacement, and certificate validation.
5. For EC2 replacement, account for application redeployment, `/opt/myapp/.env`, `/health`, host-local data, and dev WireGuard material.
6. For prod, plan around its single target and external DNS requirements.
7. Do not bypass EIP `prevent_destroy` or ALB deletion protection without confirming destruction is intended.

After apply, verify the relevant outputs and live behavior: EC2 boot logs, SSM connectivity, nginx/Docker status, application deployment, target health, HTTPS redirects, DNS, and WAF metrics.

## Known drift and gaps

- Dev is documented elsewhere as VPN-only, but 22/80/443/51820 are currently public.
- `wireguard.md` contains stale command paths and describes security-group restrictions not present in current Terraform.
- Prod user data reads the wrong SSM path and writes a dev-labelled placeholder page.
- AMI variable descriptions reference a nonexistent data-source name.
- `waf-plan.md` describes rules, logging, and outputs that differ from `waf.tf`.
- CloudWatch log groups exist without log shipping.
- The infrastructure prepares hosts but does not deploy the backend or frontend.
- Staging is only a placeholder.

Keep this file and `APPLICATION_INFRASTRUCTURE.md` synchronized with infrastructure changes, at their respective levels of detail.
