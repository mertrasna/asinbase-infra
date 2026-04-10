# asinbase-infra

Terraform code for the dev environment of Asinbase, running on AWS in eu-central-1 (frankfurt).

## Status
Work in progress. Currently setting up foundations.

## Structure
- bootstrap/ — one-time setup for the Terraform state backend (s3)
- environments/dev/ — the dev environment (VPC, EC2, IAM, SSM, Route53)