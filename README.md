# asinbase-infra

Terraform infrastructure for the Asinbase project, hosted on AWS in `eu-central-1` (Frankfurt).

Two live environments — **dev** and **prod** — that share a common base but have diverged: dev is VPN-gated with a nightly cost-saving stop/start, while prod sits behind a public ALB with TLS and a WAF.

## What's provisioned

| Layer | Dev | Prod |
|---|---|---|
| **Network** | VPC, 1 public subnet, IGW, route table | VPC, 2 public subnets (AZ a/b), IGW, route table |
| **Compute** | EC2 `t3.small` (Ubuntu 24.04), Elastic IP, 20 GB encrypted EBS | EC2 `t3.medium` (Ubuntu 24.04), Elastic IP, 30 GB encrypted EBS |
| **Edge / LB** | — (direct access over VPN) | ALB + ACM cert (`asinbase.com`, `*.asinbase.com`) + WAFv2 Web ACL |
| **Security** | SG (SSH + WireGuard UDP 51820), fail2ban, UFW | ALB SG (80/443 public) + EC2 SG (80 from ALB only, SSH), fail2ban, UFW |
| **Access** | WireGuard VPN (SSH on 22 as fallback) | Public HTTPS via ALB; SSH on 22 |
| **Cost control** | Night-Down Lambda: stop 00:00 / start 08:00 (Europe/Berlin) | — |
| **IAM** | EC2 role + profile, scoped SSM read; Night-Down + scheduler roles | EC2 role + profile, scoped SSM read |
| **Config** | SSM Parameter Store secrets, fetched into `.env` at boot | SSM Parameter Store secrets, fetched into `.env` at boot |
| **State** | S3 remote backend with locking | S3 remote backend with locking |

Each EC2 instance is bootstrapped via `user_data.sh` (installs Docker, nginx, AWS CLI, and pulls secrets from SSM on first boot). TLS terminates at the prod ALB; the instance serves plain HTTP on port 80.

> The environments are intentionally **not** shared modules — code is duplicated so each can be managed independently.

## Project structure

```
.
├── bootstrap/              # One-time S3 backend setup for Terraform state
└── environments/
    ├── dev/                # Dev: VPC, EC2, IAM, SSM, WireGuard, Night-Down Lambda
    ├── prod/               # Prod: VPC, EC2, IAM, SSM, ALB, ACM, WAF
    └── staging/            # Staging (placeholder, no Terraform yet)
```

## Usage

Each environment is self-contained — always `cd` in before running Terraform.

**Bootstrap state backend (once)**
```bash
cd bootstrap
terraform init && terraform apply
```

**Deploy an environment**
```bash
cd environments/dev      # or environments/prod
terraform init
terraform plan
terraform apply
```

`terraform plan/apply` requires the matching SSH public key locally (`~/.ssh/dev-ec2-key.pub` / `~/.ssh/prod-ec2-key.pub`). If missing, regenerate it: `ssh-keygen -y -f ~/.ssh/dev-ec2-key > ~/.ssh/dev-ec2-key.pub`.

See [CLAUDE.md](CLAUDE.md) for the detailed architecture, AMI strategy, and known caveats.

## Stack

- **IaC:** Terraform (`~> 1.10`, AWS provider `~> 6.40`)
- **Cloud:** AWS (EC2, VPC, IAM, SSM, S3, ALB, ACM, WAFv2, Lambda, EventBridge Scheduler)
- **OS:** Ubuntu 24.04 LTS
- **Runtime:** Docker + Docker Compose
- **Web server:** nginx
</content>
</invoke>
