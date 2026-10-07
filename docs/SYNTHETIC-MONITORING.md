# Synthetic monitoring: checking the app the way a user does

Roadmap step 11. Everything else in `observability/` watches the services
from the inside: their metrics, logs and traces. That's **whitebox**
monitoring, and it has two blind spots:

- it can be green while users can't get in (a broken Ingress, DNS, an
  expired certificate: no service metric changes);
- it needs traffic. At 3am with no users, the SLO alerts can't tell a
  working sign-in from a broken one.

**Blackbox** (synthetic) monitoring closes both: a robot makes the same
requests a user would, all the time, and alerts when they fail.

## What is checked

Three checks, one per service, each chosen to exercise more than "the
process is up":

| Check (`service` / `check`) | Request | Passes when | What a pass proves |
|---|---|---|---|
| `frontend` / `home` | `GET /` | 2xx | nginx serves the app |
| `order-service` / `status` | `GET /api/orders/status` | 2xx and the body has `"status":"ONLINE"` | order-service answers its API, not only its health check |
| `user-service` / `signin` | `POST /api/auth/signin` with a random password | exactly **401** | user-service, its security chain and MongoDB all answered: if MongoDB is down, sign-in returns 500 and the check fails |

The sign-in check never signs in. Its password is random, made when the
exporter's pod starts and kept only in memory: anyone can sign up, so a
password in Git would let anyone register `synthetic-probe` with it and
fail the check (and page on-call) at will. A 200 therefore means sign-in
accepted a password nobody knows. The check depends on user-service
returning 401 for wrong credentials and 500 only for its own faults (app
repo, `GlobalExceptionHandler`).

The exporter fetches whatever URL `/probe` is given, so it is locked down
like a proxy: a NetworkPolicy lets only Prometheus call it and lets it
reach only DNS and the namespaces it probes (not the node's metadata
service). It takes effect once the cluster enforces NetworkPolicy
(roadmap step 19); public-URL probes will need an egress rule added.

## Where it checks from

Where a probe starts decides what it can see:

```
                         ┌──────────── EKS / KinD cluster ─────────────┐
 CloudWatch Synthetics   │                                             │
 canary (tf, optional) ──┼─► ALB ──────────┐                           │
 every 5 min, from AWS   │   (cloud)       │                           │
                         │                 ▼                           │
                         │  blackbox ──► Traefik ──► Service ──► pod   │
                         │  exporter     (lab only,   ▲                │
                         │  every 30s     via=ingress)│                │
                         │      └─────────────────────┘                │
                         │        straight to the Service, via=service │
                         └─────────────────────────────────────────────┘
```

| From | Label | Environments | Catches |
|---|---|---|---|
| blackbox exporter → Service | `via="service"` | all | the service and what it depends on (MongoDB) |
| blackbox exporter → Traefik | `via="ingress"` | lab | the above, plus routing (Ingress paths, Traefik) |
| CloudWatch Synthetics → ALB | (CloudWatch alarm) | cloud, when enabled | the above, plus the ALB, its listener and security group, and DNS/TLS once there is a domain |

When an ingress probe fails and its service probe passes, the problem is
the way in, not the service.

The cloud's way in has no in-cluster probe yet: the ALB's DNS name is only
known after AWS creates it, and the domain comes at the end of the roadmap
(step 03). Then add Probes for the public `https://` URLs to
`observability/<env>`, as `via: public`; the TLS expiry alerts start
working with them.

## Files

```
addons/applications/blackbox-exporter.yaml     the exporter (prometheus-blackbox-exporter chart)
addons/values/common/blackbox-exporter.yaml    how to probe: the three modules, the random
                                               sign-in password, the NetworkPolicy
addons/values/cloud/blackbox-exporter.yaml     two replicas, spread over nodes
observability/components/synthetic-probes/     what to probe: one Probe per service
observability/local/edge-probes.yaml           the same checks through Traefik (lab)
observability/base/synthetic-alerts.yaml       the alerts below
observability/base/dashboards/overview.json    "Is everything OK?"
tests/prometheus/synthetic_test.yaml           the alerts' unit tests
tf: infrastructure/app-cluster/01-infra/observability.tf   canary + Container Insights
```

A `Probe` is a Prometheus Operator object: Prometheus turns it into a
scrape of `blackbox-exporter:9115/probe?module=<module>&target=<url>`. The
exporter makes the request and answers with metrics: `probe_success`
(1 or 0), `probe_duration_seconds`, `probe_http_status_code`,
`probe_ssl_earliest_cert_expiry` for HTTPS.

## Alerts

| Alert | Severity | When |
|---|---|---|
| `EndpointDown` | critical | a check has failed for 2 minutes |
| `EndpointSlow` | warning | a check succeeds but averages over 1s for 15 minutes |
| `TLSCertificateExpiringSoon` | warning / critical | under 21 / 7 days left (HTTPS targets only) |
| `SyntheticProberDown` | warning | Prometheus can't reach the exporter, so a check isn't running |
| `SyntheticProbesMissing` | warning | no checks configured at all |

What to do for each: [`runbooks.md`](runbooks.md#synthetic-checks).

## The "Is everything OK?" dashboard

One page, top to bottom: can users use it (every check, red or green),
are we within our objectives (30-day SLOs), is anything alerting, and is
the platform healthy (nodes, pods, restarts, scrape targets, the log and
trace pipelines). Start an incident here, then follow the links to
**Service Level Objectives** and **Microservices**.

## Try it in the lab

After `scripts/sync-local-stack.rb`, open Grafana (`kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring`),
dashboard **Is everything OK?**. All six checks should be green.

If ArgoCD is reconciling the lab, turn off auto-sync for `local-apps` and
`order-service` in its UI first: its self-heal would undo each break below
within minutes, before the alerts fire. Turn it back on afterwards, and
ArgoCD puts everything back.

1. **A service goes away.** `kubectl scale deploy order-service -n development --replicas=0`.
   Both order-service checks turn red; `EndpointDown` fires after 2
   minutes (Alertmanager: `kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093 -n monitoring`),
   next to `ServiceUnavailable`. Scale back to 1.
2. **The routing breaks, the service doesn't.** `kubectl edit ingress app-ingress -n development`,
   change `/api/orders` to `/api/order`. Only the `via=ingress` status
   check fails: the service check still passes. Change it back.
3. **The database goes away.** `kubectl scale statefulset mongodb -n development --replicas=0`.
   Sign-in first answers 500; then both backends drop out of their
   Services (their readiness checks include MongoDB), every backend check
   fails and `ServiceUnavailable` fires for both. Only the frontend stays
   green: the page loads and nothing behind it works, which no check of
   the frontend alone would show. Scale back to 1.
4. **Look at one probe.** `kubectl port-forward svc/blackbox-exporter 9115 -n monitoring`, then
   `curl 'localhost:9115/probe?module=http_signin_rejected&target=http://user-service.development.svc.cluster.local/api/auth/signin&debug=true'`.

## In the cloud: the canary and Container Insights

Both are in the tf repo (`infrastructure/app-cluster/01-infra/observability.tf`),
off by default because they cost money while on. To turn on in
`environments/app-cluster/<env>.tfvars` after the first ArgoCD sync:

```hcl
synthetics_base_url       = "http://<ALB DNS name>"   # kubectl get ingress app-ingress -n development
synthetics_alarm_email    = "you@example.com"          # optional
enable_container_insights = true                       # optional
```

The canary runs the same three checks through the ALB every 5 minutes;
two failed runs out of three trigger a CloudWatch alarm on an SNS topic
(`synthetics_alarm_topic_arn`). Learning topic 11 in the tf repo compares
Container Insights with the Prometheus stack.

## Synthetic traffic in the logs

Every probe request carries `User-Agent: blackbox-exporter (synthetic probe)`
(the canary: `CloudWatchSynthetics/...`). The sign-in check also writes an
`auth_signin_failed` audit line for `synthetic-probe` every 30 seconds
per probe. Filter them out when reading logs, and if anything counts
failed sign-ins (a brute-force detector, an account lockout), exempt that
user name, or the check will trip it.
