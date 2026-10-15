# Notification infrastructure and operational telemetry

Source implementation dated October 15, 2026. This is a reviewed provisioning candidate; no cloud
plan, apply, queue, partner destination, subscription, worker, email or alarm recipient was activated.
The application ticket is **Add environment isolated notification infrastructure and operational telemetry**.
Its paired application implementation owns aggregate database observations and actual-iteration telemetry.

## Isolation and activation boundary

Each Terraform root calls the small `modules/notification_operations` module with a literal environment,
its own existing runtime role/log group and its fixed Supabase project. The rest of the environment roots
remain independent. This module is the one deliberate shared contract; it neither refactors the topology
nor changes EC2, user data, networking, bootstrap or the existing Watchlist alarms.

`notification_operations_enabled=false` creates no new managed resources, including no local
`terraform_data` resource. Enabling provisioning creates standard ingress/DLQ queues, an exact partner
bus, disabled rules, consume-only runtime IAM and monitoring. It never changes application settings.
The source pins account `254527609890`, region `eu-central-1`, dev database `nehqpiqhdodkmyalpfpx`
and prod database `bbzowpqwdqamcrmwahch`. A foreign account/region/database/role/log group fails closed.

The `notification_identities` map must carry separately verified `dev` and `prod` application IDs and
exact partner source names returned by Amazon. Identical applications/sources are rejected. Matching the
format cannot establish real app ownership: retain destination response evidence and verify the Sandbox
versus production application in the separate activation review. This repository does not create Amazon
destinations/subscriptions and does not guess either identity. Rules accept only the exact environment
source and `LISTINGS_ITEM_STATUS_CHANGE` / `LISTINGS_ITEM_ISSUES_CHANGE` types; all rules stay `DISABLED`.

Each standard queue uses SQS-managed encryption, 120-second visibility and 20-second long polling.
Ingress retains four days, DLQ fourteen days; application redrive allows only its own ingress and at
most five receives. EventBridge retries at most five times within one hour, then writes its failure to
the same environment DLQ. Its attributes identify the failed rule/target; normal ingress redrive retains
its application envelope. Diagnosis/replay must distinguish those origins. Both queues and partner bus
use `prevent_destroy`; setting provisioning false after an apply is not a safe rollback procedure.

The direct publisher is only Amazon account `437568002678`, with SendMessage/GetQueueAttributes on
one exact queue. EventBridge can SendMessage only from exact rule ARNs in the approved account. TLS
is required. The runtime policy grants five receive/delete/visibility/attribute/URL actions on ingress
only; no DLQ receive, redrive, administration, purge or wildcard access. Existing EC2 credentials are
shared by HTTP/worker containers within each environment; this change does not introduce separate
per-container identities. No additional operator/redrive permissions are granted by this ticket.

## Telemetry and alarm contract

`operational-telemetry-v1.json` mirrors the application's canonical contract byte for byte, with SHA-256
sidecar. `ASINBASE_APP_CONTRACT=/path/to/app/docs/contracts/operational-telemetry-v1.json` makes offline
contract tests verify the cross-repository copy. Update both repositories together when changing pairs.

The raw JSON event must have the fixed event name, full environment, allowed metric/component pair,
finite nonnegative value and the metric's unit. Filters bake in each metric's component allowlist and
use only a bounded `Component` dimension in `Asinbase/Operations/dev` or `/prod`. Small component batches
keep filter strings below 1,024 characters and total filters below 80, leaving room for existing filters
under the 100-filter log-group quota. No seller, user, ASIN, SKU, recipient, payload or exception-text
labels are accepted. `count` and `tokens` use CloudWatch Count; metric identity distinguishes them.

Counter alarms use Sum; aggregate gauges use Maximum. Queue ages use original enqueue time and do not
reset on retry. Heartbeat counts mean completed useful iterations, including a completed idle poll;
a timer/container/HTTP response cannot establish progress. Cadence-specific missing alarms use the
canonical worker maximum gap, rounded up to a CloudWatch period, and missing data is breaching.

`notification_expected_components=[]` deliberately installs no application health expectations. Add
components only during their separately approved activation after checking the producer and capability.
Durable aggregate expectations also require `operational_metrics`, so a stalled collector cannot leave stale gauges silently healthy. Native queue/DLQ and EventBridge alarms exist when provisioned, with actions disabled by default.
Generic queue guards are 1,000 visible entries / one-hour age, and sustained provider pressure is two
of three five-minute periods. These are internal operational guards, not a customer SLA. SMTP age
warnings/alarms are exactly essential 150/300 seconds, urgent 1,800/3,600, routine 43,200/86,400.
Rolling attempts alarm at 100 essential, 250 catalog, 50 other and 400 total. The mailbox allocation
includes independent Supabase Auth and any other mailbox users; app SMTP counters do not prove it.

Missing lifecycle/shared-email-governor and recipient-observed delivery producers emit
`CapabilityUnavailable`, never healthy zero gauges. Their future alarm interfaces exist but remain
unarmed until explicit expected-component acceptance. SMTP attempts, SMTP acceptance, inbox records
and observed mailbox arrival remain distinct. No recommendation email channel is created. Recommendation
cost/yield/rejection/withdrawal/kill-switch pairs are finite interfaces for the downstream owners.

Alarm actions need both `notification_alarm_actions_enabled=true` and exact existing environment-owned
SNS topic ARNs under `asinbase-dev-*` or `asinbase-prod-*` in this account/region. No SNS topic,
subscription, email address or alert is created/sent here. An approved operator must test alarm and
recovery routing before enabling it; missing telemetry must not be accepted as zero backlog.

## Local verification and source promotion

```sh
terraform -chdir=modules/notification_operations init -backend=false -input=false -lockfile=readonly
terraform -chdir=modules/notification_operations fmt -check -recursive
terraform -chdir=modules/notification_operations validate
terraform -chdir=modules/notification_operations test
python3 -m unittest discover -s tests -p test_notification_contract.py -v
```

Native Terraform tests use `mock_provider` and `command = plan`, not AWS. No credentials, remote state,
cloud API, real plan or apply is involved. They exercise disabled/default resources, independent dev/prod
identities and permissions, negative foreign identities/destinations, thresholds and missing progress.
The module's new lockfile pins its test provider; existing environment provider lockfiles stay unchanged.

Source promotion is branch → `dev` → `main`, with the new read-only GitHub contract workflow green at
each revision. Infrastructure had no dev branch before this work; create it from current main for this
staged source promotion, without applying either environment. App code follows its own dev/main CI/CD.
An app deployment still has all new telemetry gates false and cannot provision these resources.

## Separate approved operator steps

1. Review the application SSM audit (`docs/audits/2026-10-01-ssm-configuration`) and later production
   adoption records. Old bootstrap `/opt/myapp/.env` is not the active Compose `backend/.env`. Verify
   both generated runtime files/containers. Production user-data's wrong SSM path is a known separate
   replacement-sensitive defect; do not incidentally modify it. EC2 replacement needs its own recovery
   plan, including retained prod disk, single ALB target and dev WireGuard material.
2. Obtain separate authorization for read-only hosted planning. Confirm account, region, Supabase
   target, exact provider app/source identities, queue/bus names, runtime role and current absence or
   ownership of resources. Inspect existing remote state and reject unintended replacement/deletion.
   No real state/backend or host evidence was refreshed by these offline contract checks.
3. Obtain separate provider authorization for destination creation if the exact partner sources do not
   yet exist. Source association must use Amazon's actual response; obtain the second environment's
   distinct identity before allowing this module's provisioned plan.
4. Review a saved dev plan with all rules DISABLED, application gates false, and no unrelated EC2,
   user-data, security group, SSM, logging or existing-alarm changes. Obtain explicit apply approval.
   Validate each output against actual AWS resources and effective runtime IAM after that apply.
5. Adopt the separately reviewed app telemetry migration using its explicit-target backup/adoption
   workflow. Deploy source with `ENABLE_WORKER_RUNTIME`, `ENABLE_OPERATIONAL_TELEMETRY`,
   `ENABLE_OPERATIONAL_METRICS_WORKER`, notification workers, outbound email and Amazon mutations false.
   Handoff outputs are proposals only: write SSM only in a separately authorized configuration action.
6. Verify log shipping and the telemetry schema/capabilities using owned noncustomer fixtures. Authorize
   the minimum sandbox canary separately, then observe/reconcile destinations without apply. Verify
   event receipt, quarantine, dedupe, lease recovery, DLQ, cross-environment denial and exact sender
   routing without treating sandbox receipt as real-seller acceptance. Enable each expectation/alert
   action only when the corresponding consumer has been accepted.
7. Repeat the approved plan/apply/adoption/canary sequence for production. Worker scheduling, provider
   mutations and customer/email delivery require their independent acceptance. App/infrastructure code
   merge alone never supplies that acceptance.

Rollback: first restore application stop gates, keep provider reconciliation in observe mode, disable
EventBridge rules and alarm actions through separately approved operations, and reconcile containers.
Preserve queues, DLQ, database ledger and event destinations for diagnosis. Do not purge, delete,
blindly redrive or set provisioning false. Stop gates prevent work; retained queues preserve evidence.

## Official references checked October 15, 2026

- [Amazon EventBridge notification setup](https://developer-docs.amazon/sp-api/docs/set-up-notifications-with-amazon-eventbridge): exact partner source identity and event-type filtering.
- [Amazon SQS notification setup](https://developer-docs.amazon/sp-api/docs/set-up-notifications-with-amazon-sqs): direct publisher workflow and separate provider destination/subscription actions.
- [Notification type values](https://developer-docs.amazon/sp-api/docs/notification-type-values): listing status/issues use EventBridge; issues payload version 2023-12-13 remains the accepted version.
- [EventBridge resource policies](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-use-resource-based.html): exact source-rule SQS permissions.
- [SQS encryption](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-server-side-encryption.html): SQS-managed versus KMS-managed encryption and HTTPS requirements. No CMK/key policy is needed for the selected SSE-SQS mode.
- [EventBridge metrics](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-monitoring.html): failed invocation is a terminal failure metric; delivery is best effort. Actual metric/dimension appearance remains an activation check.
