# Asinbase infrastructure context for application agents

Use this file when working on the Asinbase backend or frontend. It describes the infrastructure contract the application must satisfy. It is based on the current Terraform and boot scripts in `asinbase-infra`, not on the older design documents.

If behavior here conflicts with the infrastructure code, the `.tf` files and `user_data.sh` files are the source of truth. Ask for an infrastructure change instead of silently coding around a platform constraint that should be changed centrally.

## What runs where

Asinbase has two live AWS environments in `eu-central-1`:

| | Dev | Prod |
|---|---|---|
| Compute | One Ubuntu 24.04 EC2, `t3.small` by default | One Ubuntu 24.04 EC2, `t3.medium` |
| App runtime prepared by infra | Docker Engine, Docker Compose, nginx | Docker Engine, Docker Compose, nginx |
| Public web entry | Directly through the EC2 Elastic IP on 80/443 | Through an ALB with ACM TLS and WAF |
| App traffic reaching the host | Direct HTTP/HTTPS | Plain HTTP on port 80 from the ALB |
| Availability | Stopped every day 00:00–08:00 Europe/Berlin | Always intended to be on, but only one app instance |
| Secrets path | SSM `/dev/backend/*` | SSM `/prod/backend/*` intended; see known bug below |
| Host app directory | `/opt/myapp` | `/opt/myapp` |

There is no Kubernetes, ECS, autoscaling group, managed database, Redis, S3 application bucket, CloudFront distribution, deployment pipeline, or frontend-specific hosting in this repository. The application currently runs on a single host per environment. The two-subnet prod ALB is multi-AZ, but its only target is one EC2 instance in availability zone `eu-central-1a`; prod is not application-level high availability.

Infrastructure prepares the servers but does not deploy either the backend or frontend. Application deployment, Docker Compose definitions, image delivery, nginx application config, process supervision inside containers, and database services/migrations must be handled by the application/deployment repositories.

## Request paths

### Production

```text
Browser / API client
  -> WAF-protected public ALB
  -> port 80 redirects to HTTPS
  -> ACM terminates TLS on port 443
  -> apex asinbase.com redirects to https://www.asinbase.com
  -> all other requests go to one target group
  -> EC2 nginx/app over HTTP port 80
```

The ALB is the production TLS boundary. Do not require the backend container itself to terminate public TLS. The EC2 security group accepts web traffic on port 80 only from the ALB security group; direct public HTTPS to the EC2 is not configured.

There are no API-specific host or path routing rules in Terraform. Other than the apex-domain redirect, every host/path reaching the ALB is sent to the same target group. If frontend and backend share this deployment, nginx or the application stack must route paths such as `/api/*`, static assets, and frontend fallbacks.

The certificate covers:

- `asinbase.com`
- `*.asinbase.com`

DNS is managed outside Terraform, currently through Namecheap. Do not assume Route 53 records exist or can be changed from application code. Terraform outputs the ALB hostname and certificate validation CNAMEs for a human to configure externally.

The ALB idle timeout is 60 seconds. Requests that produce no data for longer than that can be closed by the load balancer. Long-running HTTP handlers, streaming, SSE, or WebSocket behavior must be tested through the ALB, not only locally. If a longer timeout is required, coordinate changes to the ALB, nginx, and application server together.

AWS ALB forwarding means the app/nginx layer should handle proxy headers correctly, especially the original scheme and client IP. HTTPS redirects, secure cookies, generated absolute URLs, rate limiting, and logs should use the forwarded request context rather than assuming the EC2 connection itself is HTTPS.

### Development

Dev currently exposes the EC2 Elastic IP directly on:

- TCP 22 for SSH
- TCP 80 for HTTP
- TCP 443 for HTTPS
- UDP 51820 for WireGuard

All four are open to `0.0.0.0/0` in the actual Terraform. Older infrastructure documents describe dev as VPN-only, but that is no longer true: public 80/443 were opened for external webhooks such as Dodo Payments, and public SSH remains as a fallback.

An open dev port 443 does not mean TLS is ready on a fresh instance. Terraform does not create a dev certificate, and user data does not configure nginx TLS; the application/deployment layer must supply that configuration if dev HTTPS is required.

WireGuard may also be configured manually on the dev host. Its server address is `192.168.100.1`, but WireGuard is not installed by Terraform or by EC2 user data. Application code must not depend on the VPN being the only route to dev.

Dev is automatically stopped at 00:00 and started at 08:00 in the `Europe/Berlin` timezone every day. AWS handles daylight-saving changes. Failed dev requests overnight may simply mean the environment is intentionally offline. The Elastic IP and disk survive the scheduled stop/start.

## Backend contract

The production deployment must satisfy all of these:

1. Serve HTTP on the EC2 host's port 80, normally by putting the backend/container behind nginx.
2. Return exactly HTTP `200` for `GET /health` without authentication.
3. Make `/health` fast and suitable for a load-balancer probe every 30 seconds.
4. Start again after an EC2 reboot. Docker is enabled at boot, but application containers are not started by this repository; use an appropriate restart policy or host service in the deployment setup.
5. Read runtime secrets from the server environment file or inject that file into the container deliberately.
6. Respect reverse-proxy headers and the 60-second ALB idle timeout.
7. Avoid assuming local disk is durable across instance replacement.

The prod target group uses these health-check settings:

| Setting | Value |
|---|---|
| Method/path | `GET /health` |
| Protocol/port | HTTP on traffic port 80 |
| Expected status | `200` only |
| Interval | 30 seconds |
| Timeout | 5 seconds |
| Healthy threshold | 2 successes |
| Unhealthy threshold | 3 failures |
| Deregistration delay | 30 seconds |

A fresh infrastructure-only instance serves an nginx placeholder page but has no `/health`, so it remains unhealthy until the application/nginx deployment supplies that endpoint. Do not change the endpoint in backend code without coordinating the target-group setting.

The target group has one instance. Deployments that stop nginx or the backend cause production downtime unless the deployment process introduces its own handover strategy. Graceful shutdown should allow in-flight requests to finish within the 30-second target deregistration window when deregistration is actually used.

## Frontend contract

The infrastructure does not independently build or host frontend assets. There is no S3/CloudFront static site. The current platform expects the application deployment to choose one of these patterns on the same EC2 target:

- nginx serves the built frontend and proxies API routes to the backend container; or
- an application container serves both frontend and backend traffic behind nginx.

Terraform does not define a separate API domain, CORS policy, content-security policy, cache policy, or SPA fallback. Those belong to nginx/application configuration unless new infrastructure is explicitly added.

Production's canonical browser host is intended to be `www.asinbase.com`; requests to `asinbase.com` are redirected there. Frontend environment variables and canonical URL/SEO configuration should therefore use the `www` origin unless the application architecture deliberately introduces another hostname. A wildcard certificate alone does not create DNS records or routing for a subdomain.

Never expose values from `/opt/myapp/.env` to a client-side bundle unless they are explicitly public configuration. The file is intended for backend/runtime secrets.

## Runtime configuration and secrets

At first boot, user data creates `/opt/myapp/.env`. It requests every SSM parameter below the environment path, takes the final path component, uppercases it, and writes:

```text
/dev/backend/database_url -> DATABASE_URL=<value>
```

The resulting file is owned by `ubuntu`, has mode `0600`, and is not automatically loaded into Docker containers. The deployment must explicitly pass it, for example through the chosen Docker Compose configuration. Do not commit a copy to an application repository or bake it into a frontend image.

Important limitations:

- Secrets are fetched only during EC2 first boot. Changing an SSM parameter does not refresh the file automatically.
- Parameters with the same basename collide after flattening, even if their parent paths differ.
- No SSM parameter values are created by this infrastructure repository; they must already exist.
- The EC2 IAM role can read only its own environment's path.

Known production bug: `environments/prod/user_data.sh` currently requests `/dev/backend/`, while the prod IAM role permits only `/prod/*`. The error is suppressed and the script normally writes `# No SSM params yet`. A new prod instance therefore does not receive its intended secrets from infrastructure. Do not assume `/opt/myapp/.env` is valid in prod; verify it during deployment. Fixing the boot script itself forces EC2 replacement, so this needs a planned infrastructure migration rather than a casual edit.

## Host behavior relevant to deployments

Both hosts are bootstrapped with:

- Ubuntu 24.04 Noble amd64
- Docker Engine, Buildx, and Docker Compose plugin
- nginx
- Git, curl, unzip, and AWS CLI v2
- UFW, fail2ban, and unattended security upgrades
- Docker JSON logs rotated at 10 MiB with 3 files
- user `ubuntu`, which is added to the `docker` group

User-data logs are local at `/var/log/user-data.log`. The default nginx content is only a placeholder and even says `Dev server ready` in prod.

Terraform creates these CloudWatch log groups:

- `/asinbase-backend/dev`, retained 7 days
- `/asinbase-backend/prod`, retained 14 days

Terraform does not configure a CloudWatch agent or Docker logging driver. The application repository's development and production Compose files supply that runtime integration with Docker's `awslogs` driver and fixed `backend` and `worker` streams. Application deployments must preserve those group and stream names; replacing the Compose logging configuration would silently break the metrics below even though Terraform remained healthy.

Both environments also define Watchlist threshold observability from raw JSON events on the application log group. Metric filters publish into separate `Asinbase/WatchlistThresholds/dev` and `Asinbase/WatchlistThresholds/prod` namespaces. CloudWatch alarms cover:

- no successful `watchlist_threshold_evaluation_complete` event for 26 consecutive hours;
- `oldest_pending_age_seconds` above 24 hours in a `watchlist_threshold_delivery_health` event;
- any failed delivery-health database read (`success: false`);
- any `watchlist_threshold_dead_batch` event;
- `fresh_cache_coverage_pct` below the configured threshold, initially 90%;
- successful-run `trigger_volume` (live `triggered` plus shadow `would_trigger`) outside a two-standard-deviation CloudWatch anomaly band.

The trigger-volume filter emits zero during non-evaluation periods and the alarm aggregates hourly, allowing CloudWatch to learn the expected daily run pattern during shadow as well as live delivery. A new anomaly model can take up to two weeks to train; verify and tune it during shadow/canary rollout rather than treating its initial band as authoritative.

These filters require the complete log event to be valid JSON; JSON embedded inside the application's normal prefixed text formatter does not match. Only events with JSON boolean `success: true` update normal health metrics. A `success: false` delivery-health event updates a separate failure metric, so a failed database health read alerts without resetting an existing pending-age alarm. Successful delivery health must report zero for an empty pending queue, and an evaluation with no configured metrics must report 100% coverage so alarms can recover cleanly.

Terraform always creates the environment's SNS topic, but alarm actions are disabled by default. Supplying `watchlist_threshold_alarm_email` enables alarm and recovery actions and creates an email subscription; the recipient must confirm that subscription before notifications are delivered. The missing-evaluation alarm treats absent data as breaching, so produce and verify a successful event after first apply before enabling email actions.

The EC2 role includes `AmazonSSMManagedInstanceCore`, so SSM Session Manager is intended as an administrative access method. SSH also remains public in both environments. Application code should not need AWS credentials on disk; software using the AWS SDK on EC2 should use the instance role when its permissions are sufficient.

Both EC2 security groups allow unrestricted outbound traffic and the instances are in public subnets with an internet-gateway route, so containers can reach external APIs unless the host/container configuration adds another restriction.

## Production WAF behavior

The regional WAF is attached to the ALB and defaults to allowing requests. These rules are currently enforced:

- AWS Amazon IP Reputation managed rules
- AWS Known Bad Inputs managed rules
- per-source-IP rate limit: more than 2,000 requests in 5 minutes is blocked

These rules currently count matches but do not block them:

- AWS Common Rule Set
- AWS SQL injection rules
- AWS Linux rules

CloudWatch metrics and sampled requests are enabled, but full WAF request logging is not configured. If a request works directly on the host but receives a production `403`, investigate WAF sampled requests and metrics. Legitimate high-rate clients, shared NAT users, webhooks, unusual query strings, uploads, or SQL-like text can interact with these controls; test such flows through the real production entry point.

Do not rely on count-only rules remaining non-blocking forever. If the infrastructure team promotes them to enforced actions, application endpoints with false-positive patterns may need a scoped WAF exclusion rather than unsafe input-handling changes.

## Persistence, replacements, and deploy safety

Scheduled dev shutdown is only a stop/start and preserves the instance and volume. Terraform-driven replacement is different:

- Dev's 20 GiB root disk is deleted when its instance is terminated. Manual WireGuard keys/config and any application data stored only on that disk are lost.
- Prod's 30 GiB root disk is retained after termination, but Terraform does not attach the old disk to the replacement. The new instance starts with a new blank root disk, and the retained one can become an orphaned volume.
- Both Elastic IP resources are protected from Terraform destruction and normally remain stable across instance replacement.
- Any change to either `user_data.sh` is configured to replace the EC2 instance.
- Prod's ALB has deletion protection enabled.

Application deployments should treat instances as replaceable and keep source, images, migrations, backups, and required configuration reproducible outside the host. Do not use the root disk as the sole store for production user data or database state.

There is no automatic app redeployment after Terraform replaces an instance. Infrastructure can report success while the new target is still serving only the placeholder page and failing `/health`. A replacement is complete only after the application is deployed, runtime configuration is verified, and the target is healthy.

## What application agents must not assume

- Dev is not currently private or VPN-only.
- Prod is not horizontally scaled or zero-downtime by default.
- The two prod ALB subnets do not mean there are two backend servers.
- TLS continues to the prod container; it terminates at the ALB.
- `/health` exists automatically; the app/deployment must provide it.
- SSM changes automatically reach a running app.
- Prod's boot-generated `.env` is correct; it currently has a path bug.
- Terraform alone configures CloudWatch application log shipping; the required Docker `awslogs` integration lives in the application repository.
- All application log lines are structured JSON; only the dedicated Watchlist threshold health events have that contract.
- A wildcard certificate means a subdomain has DNS or separate routing.
- Frontend hosting, API routing, CORS, backups, monitoring, alerts, or CI/CD are supplied by this repository.
- Data written to an EC2 root disk survives a Terraform replacement in a usable, attached form.

## When backend/frontend changes require infrastructure coordination

Coordinate with the infrastructure repository when a feature needs:

- a new public port, protocol, hostname, certificate name, DNS record, or ALB route;
- a health endpoint other than `GET /health` returning 200;
- requests idle for more than 60 seconds;
- WAF exclusions or a higher/lower rate limit;
- new AWS permissions for the EC2 instance role;
- new SSM paths or a different environment-variable materialization scheme;
- managed data services, durable storage, queues, buckets, or caches;
- more than one production target, autoscaling, or zero-downtime deployment support;
- real CloudWatch log shipping, alarms, dashboards, or tracing;
- a separate static frontend/CDN deployment;
- changes to dev's nightly availability window or network exposure.

## Infrastructure source map

For questions that require checking implementation, use these files in `asinbase-infra`:

| Concern | Source of truth |
|---|---|
| Dev/prod network | `environments/<env>/network.tf` |
| Open ports and traffic sources | `environments/<env>/security.tf` |
| Instance type, disk, AMI, replacement behavior | `environments/<env>/ec2.tf` |
| Host packages and `.env` generation | `environments/<env>/user_data.sh` |
| IAM and log groups | `environments/<env>/iam.tf` |
| Watchlist threshold metrics, alarms, and SNS | `environments/<env>/watchlist_threshold_observability.tf` |
| Dev stop/start window | `environments/dev/night_down.tf` |
| Manual dev VPN | `environments/dev/setup-wireguard.sh` |
| Production listener, routing, timeout, health check | `environments/prod/alb.tf` |
| Production certificate | `environments/prod/acm.tf` |
| Production request filtering | `environments/prod/waf.tf` |
| Addresses and DNS handoff values | `environments/<env>/outputs.tf` |

The older `environments/dev/wireguard.md` and `environments/prod/waf-plan.md` describe intended or historical states and have known drift. Verify behavior in code before making application assumptions.
