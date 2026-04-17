# asinbase-infra

Terraform infrastructure for the Asinbase project, hosted on AWS in `eu-central-1` (Frankfurt).

## What's provisioned

| Layer | Resources |
|---|---|
| **Network** | VPC, public subnet, internet gateway, route table |
| **Compute** | EC2 t3.micro (Ubuntu 24.04), Elastic IP, encrypted EBS |
| **Security** | Security group (SSH/HTTP/HTTPS), fail2ban, UFW |
| **IAM** | EC2 instance role + profile, scoped SSM read policy |
| **Config** | SSM Parameter Store for secrets, fetched into `.env` at boot |
| **State** | S3 remote backend with versioning (bootstrapped separately) |

The EC2 instance is bootstrapped via `user_data.sh` which installs Docker, nginx, AWS CLI, and pulls secrets from SSM on first boot.

## Project structure

```
.
├── bootstrap/              # One-time S3 backend setup for Terraform state
└── environments/
    ├── dev/                # Dev environment (VPC, EC2, IAM, SSM)
    └── staging/            # Staging (planned)
```

## Usage

**Bootstrap state backend (once)**
```bash
cd bootstrap
terraform init && terraform apply
```

**Deploy dev environment**
```bash
cd environments/dev
terraform init
terraform plan
terraform apply
```

## Stack

- **IaC:** Terraform
- **Cloud:** AWS (EC2, VPC, IAM, SSM, S3)
- **OS:** Ubuntu 24.04 LTS
- **Runtime:** Docker + Docker Compose
- **Web server:** nginx
