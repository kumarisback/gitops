# How this repo is organised

A plain-language guide to the repository layout and to the changes made on
branch `05-storage-statefulsets` (October 2026). Each section says what a
folder is for, what changed and why, with a small diagram where it helps.
New terms are explained in the [glossary](#glossary) at the end.

For the end-to-end picture of logs, traces and metrics, open
[`observability-pipeline.html`](observability-pipeline.html) in a browser.

---

## 1. What this repo does

This is a **GitOps** repo: Git describes what should run in each cluster,
and ArgoCD keeps the cluster matching Git.

```
 you edit YAML  ──►  Git (gitops repo)  ──►  ArgoCD  ──►  Kubernetes cluster
                                              (copies Git into the cluster
                                               and keeps it that way)
```

Each cluster (local lab, dev, staging, prod) has an **entry folder**,
`bootstrap/envs/<env>`. ArgoCD starts from there.

---

## 2. Folder map

`★` marks folders added on this branch.

```
gitops/
├── apps/                    the 3 services: frontend and user-service with Kustomize,
│   │                          order-service with our own Helm chart (charts/, docs/HELM.md)
│   ├── base/                  shared YAML for all environments
│   ├── components/  ★         shared settings used by all envs: tracing
│   │                            (otel-instrumentation) and request payload
│   │                            logging (request-logging), quotas and default
│   │                            limits per namespace (namespace-guardrails)
│   └── local|dev|staging|prod/  only what differs per environment (the lab also
│                                runs its own MongoDB: apps/local/mongodb.yaml)
│
├── addons/  ★               the "tools": Prometheus, Grafana, Loki, Tempo, collector, Alloy,
│                            metrics-server, VPA (recommends container sizes)
│   ├── applications/          one ArgoCD app per tool
│   ├── values/                the tools' settings, in layers (section 3)
│   └── select-env/            picks the right layers for each environment
│
├── observability/  ★        alerts, SLOs, dashboards, alerting secrets
├── charts/  ★               our own Helm charts: microservice (any of the services) and
│                            common (a library of shared helpers); see HELM.md
├── bootstrap/               ArgoCD entry points, one per environment
├── platform/                cluster-wide settings for the cloud clusters: RBAC,
│                            the AWS secret store, disk types (storage/), and
│                            dev's Karpenter node pools (karpenter/dev)
├── tests/  ★                tests for the alert rules and the log pipeline
├── ci/  ★                   Docker image with all the checking tools (for Jenkins)
├── scripts/                 lab scripts, plus validate.sh ★ (checks everything) and
│                            alert-drill.sh ★ (breaks a service, checks the alert fires)
├── local-setup/             lab-only settings: Traefik ingress, gp3 StorageClass
└── docs/                    this guide, the pipeline page, runbooks.md ★
```

**Removed:** each tool used to have two full copies, one in
`bootstrap/envs/local/` and one in `bootstrap/projects/`. Promtail was
replaced by Alloy everywhere.

---

## 3. Tools are defined once, with settings in layers (`addons/`)

**Before:** every tool (Loki, for example) existed twice. When one copy was
fixed and the other forgotten, they drifted apart, and several real bugs
came from exactly that.

**Now:** one definition, and the settings stack up like layers. A later
layer wins over an earlier one.

```
            addons/applications/loki.yaml      ← "install Loki chart 6.6.2" (only once)
                         │
     settings, read top to bottom:
     ┌────────────────────────────────────────────────┐
     │ values/common/loki.yaml   every environment     │
     │ values/local/loki.yaml    laptop: small, disk   │  ← the lab uses "local"
     │   or                                            │
     │ values/cloud/loki.yaml    AWS: S3, 3 copies     │  ← dev/staging/prod use "cloud"
     │ values/prod/loki.yaml     only if prod differs  │  (optional)
     └────────────────────────────────────────────────┘
```

Each `bootstrap/envs/<env>/kustomization.yaml` only says which tier and
environment it is (for example `cloud` + `prod`). The `addons/select-env`
component fills those words into the file paths above.

**Example:** to change Loki's retention in prod only, create
`addons/values/prod/loki.yaml` with just that setting.

---

## 4. Shared app tracing settings (`apps/components/otel-instrumentation`)

**Before:** each of the 4 environment folders repeated about 100 lines of
`OTEL_*` settings.

**Now:**

```
apps/components/otel-instrumentation   ← shared settings (where to send traces, ...)
            +
apps/prod/kustomization.yaml           ← a few lines: environment name, sampler
```

---

## 5. Alerts, SLOs and dashboards (`observability/`)

**Before:** alerts and the dashboard existed only in the local lab, so dev,
staging and prod had none.

**Now** they are deployed to every environment:

```
observability/
├── base/                      deployed to EVERY environment
│   ├── slo-rules.yaml           SLOs: 99.5% of requests OK, 99% under 500ms
│   ├── service-alerts.yaml      "a service is down"
│   ├── pipeline-alerts.yaml     "logs or traces stopped flowing"
│   └── dashboards/              Microservices and SLO dashboards (JSON)
├── components/
│   ├── cloud-secrets/           Slack, PagerDuty and Grafana secrets from AWS Secrets Manager
│   └── browser-otlp-alb/        cloud route for browser traces (/otlp)
└── local|dev|staging|prod/      picks what each environment needs
```

Every alert links to its section in [`runbooks.md`](runbooks.md), which says
what it means and what to do.

---

## 6. How logs flow

```
 Traefik (ingress) ─► stdout (JSON) ─┐
 Spring app ────────► stdout (JSON) ─┴► Alloy ─────────────────────────► Loki ─► Grafana
                                         │ 1. hides passwords, tokens, JWTs
                                         │ 2. labels: log_type = edge | api | server
                                         │ 3. tenant: apps (the app namespaces)
                                         │            platform (everything else)
                                         │ 4. joins multi-line stack traces (Spring apps only)
```

One request leaves up to three kinds of line, all with the same `trace_id`:

```
 client ──► Traefik ─────────────► service ─────────────────────────► (code runs)
            edge line:               api line:                          server lines:
            what the client got      method, route, status, duration,   business events,
            (status, total time)     payload where enabled              errors
```

- **Edge log:** one line per request at the entrance. Lab: Traefik. Cloud:
  the ALB writes it to S3 (switched on per environment, see
  `apps/base/ingress.yaml`).
- **API log:** one line per HTTP request inside the service
  (`RequestLoggingFilter`). Health checks are not logged.
- **Server log:** everything else the service writes.
- **Request payloads** are in the API log only where the environment turns
  them on (`apps/components/request-logging`): every request in local and
  dev, failed requests only in staging and prod. Secret fields are masked,
  and response bodies are never logged.
- In Grafana, the Microservices dashboard has **API calls** and **Edge
  requests** panels; in Explore use `{log_type="api"}` and so on.

The **tenant** split stops system logs from using up the application logs'
limits. In the cloud, app logs are kept 30 days and platform logs 7 days.

---

## 7. How traces flow

```
 Browser ──/otlp──┐
 Traefik ─────────┼──► Collector GATEWAY ──by trace ID──► Collector SAMPLER ──► Tempo
 Java apps ───────┘    (adds pod/namespace info)            │  keeps: all errors,
                                                            │  all slow (>500ms),
                                                            │  N% of the rest
                                                            └──► metrics from ALL spans ──► Prometheus
```

- **Before:** the apps threw away most traces up front. Prod kept only 10%,
  error traces included.
- **Now:** every trace is sent, and the sampler decides after seeing the
  whole trace, so an error trace is never lost. It keeps 100% of the rest in
  the lab and dev, 50% in staging and 10% in prod.
- **Why two tiers:** with two or more sampler copies, all pieces of one trace
  must reach the same copy. The gateway routes them by trace ID.
- **Browser:** the frontend sends its own span, so a trace starts in the
  browser and the console shows the same trace ID as the backend logs.

---

## 8. How alerts reach people

```
 Prometheus rules ──► Alertmanager ──► critical ─► PagerDuty + Slack
                                   ──► warning  ─► Slack
                                   ──► Watchdog ─► heartbeat check (if it stops, alerting is broken)
```

In the local lab, alerts are only shown in Grafana and the Alertmanager UI.

---

## 9. The safety net: checks before anything is deployed

```
 change YAML ─► ./scripts/validate.sh ─► Jenkins (same checks, ci/Dockerfile) ─► pull request ─► merge ─► ArgoCD
                 ├─ builds every environment
                 ├─ checks YAML against Kubernetes schemas
                 ├─ runs each tool's own config checker (Alloy, collector, Loki, Alertmanager)
                 ├─ runs the alert unit tests (tests/prometheus)
                 └─ runs a real Alloy on sample log lines (tests/alloy)
```

Run `./scripts/validate.sh` before every push. The Jenkins image-update job
opens a pull request instead of pushing straight to `main`.

---

## 10. Local lab

- **Traefik** replaced ingress-nginx, which is no longer maintained. It does
  the same job: routes `/`, `/api` and `/otlp`.
- **`start-lab-podman.sh`** deploys only through `sync-local-stack.rb`, so
  ArgoCD and the script don't undo each other's changes.
- **`sync-local-stack.rb`** reads the same `addons/` files ArgoCD uses;
  `--dry-run` prints what it would do.
- **MongoDB in the lab** (`apps/local/mongodb.yaml`): a StatefulSet with its
  own volume, so the services need no external database or secrets file.
  Put an Atlas URI in the git-ignored `apps/local/app-secrets.env` to use
  Atlas instead.

Day-to-day commands are in [`LOCAL-LAB-GUIDE.md`](../LOCAL-LAB-GUIDE.md).

---

## 11. Application repo (branch `feat/browser-tracing`)

- The frontend uses the OpenTelemetry browser SDK and sends its spans to
  `/otlp`.
- The `environment` field in logs comes from `DEPLOYMENT_ENVIRONMENT`, so
  logs say `local`, `dev`, `staging` or `production` correctly.
- The frontend image is built on Node 24, because Node 20 is out of support.
- The API log uses OpenTelemetry field names (`http.request.method`,
  `http.route`, `http.response.status_code`, ...) and can include the masked
  request payload, controlled by `APP_HTTP_LOGGING_REQUEST_BODY`
  (NEVER / ERRORS / ALWAYS). It has unit tests.

---

## Glossary

| Term | Meaning |
|---|---|
| **Helm chart** | A packaged app (for example Loki) you install with settings ("values"). |
| **Kustomize component** | A reusable piece of YAML that several folders can include. |
| **SLO** | A promise, e.g. "99.5% of requests succeed over 30 days". |
| **Error budget** | The failures the SLO allows: 0.5% of requests. |
| **Burn rate** | How fast the budget is being used up. 14.4x means the month's budget is gone in about two days. |
| **Tail sampling** | Deciding which traces to keep *after* seeing the whole trace. |
| **Tenant** | A separate "drawer" in Loki with its own limits and retention. |
| **Exemplar** | A trace ID attached to a metric point; click it to open that trace. |
| **ExternalSecret** | Copies a secret from AWS Secrets Manager into Kubernetes. |
| **IRSA** | Lets a pod use an AWS role without storing any password. |

## Suggested reading order

1. `bootstrap/envs/local/kustomization.yaml`: where the lab starts
2. `addons/applications/loki.yaml`: what one tool's definition looks like
3. `addons/values/*/loki.yaml`: how its settings are layered
4. `apps/local/kustomization.yaml`: the lab's version of the services
5. `observability/base/`: alerts, SLOs, dashboards
6. [`runbooks.md`](runbooks.md): what to do when an alert fires
