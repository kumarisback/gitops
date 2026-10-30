# Roadmap changes, in plain words

This file explains, without assuming you've read the code, what has changed in the three
repos as the learning roadmap (`LEARNING-ROADMAP.md`) is worked through:

- **app** (`kumarisback/Devops_k8_manually`): the services' source code (frontend,
  user-service, order-service, and from step 12 notification-service).
- **gitops** (`kumarisback/gitops`): everything Kubernetes runs, deployed by ArgoCD.
- **tf** (`kumarisback/terraform`): the AWS infrastructure, in Terraform.

Part 1 is what was merged into `main` before the remaining steps started. Part 2 is the
plan for every remaining phase, filled in with what actually changed as each step is done.
The same file is kept in the gitops repo (`docs/ROADMAP-CHANGES.md`) and the tf repo
(`ROADMAP-CHANGES.md`).

Each step's learning notes are in the tf repo's `learning-topics/`, and each step's
how-to guide is in gitops `docs/`.

---

## Part 1 — What was merged into `main` (2026-10-26)

Until now every step lived on its own branch. On 2026-10-26 the finished branches were
merged into each repo's local `main`:

| Repo | Merged | How | New commits on `main` |
|---|---|---|---|
| app | `fix/client-error-status` (which already contained `feat/browser-tracing`, `fix/log-environment-field` and `grafana-backup`), then `complete-phase-a-b` | fast-forward, then one merge commit | 8 |
| gitops | `11-synthetic-blackbox` (which already contained `complete-phase-a-b`, `05-storage-statefulsets`, `06-helm-authoring`, `grafana-backup` and the older step branches) | fast-forward | 132 |
| tf | `11-synthetic-blackbox` (which already contained `complete-phase-a-b`, `05-storage-statefulsets` and `06-helm-authoring`) | fast-forward | 28 |

**Not merged, on purpose:**

- gitops `elk-logging`: the same platform with ELK (Elasticsearch, Filebeat, Kibana)
  instead of Loki. It's an alternative to pick instead of `main`, not an addition.
- the `grafana-backup` branches: snapshots taken before the ELK experiment; everything in
  them is already in `main`.

The merge was done locally. GitHub's `main` is unchanged: the branch
`remaining-roadmap-steps` (Part 2) is built on top of the merged `main`, so merging that one
branch on GitHub brings in everything, Part 1 included.

### What that merge contains, step by step

**The local lab.** A KinD cluster on your own machine (Docker or Podman), set up by
`scripts/start-lab.sh`: ArgoCD, Traefik as the ingress, MongoDB inside the cluster, the
three services, and the full monitoring stack. `scripts/sync-local-stack.rb` installs the
same things ArgoCD would, straight from the repo.

**Step 01, access control.** Kubernetes RBAC: an `sre` group that can operate the
development namespace, read-only access for others. Every cloud namespace has a quota and
default limits, sized to what the autoscalers can reach.

**Step 02, production-ready workloads.** Every Deployment has startup/readiness/liveness
probes, a disruption budget, spreading over nodes and zones, graceful shutdown, and runs as
a non-root user with a read-only filesystem. Images are pinned to the git commit they were
built from, and ECR refuses to overwrite a tag.

**Step 03, ingress (partly).** One shared AWS load balancer routes `/api/orders`, `/api`
and `/` to the right service. The domain, TLS certificate and DNS records wait for the end.

**Step 04, autoscaling.** Horizontal autoscalers on CPU for every service, a Vertical Pod
Autoscaler that only recommends sizes, and Karpenter adding and removing EC2 nodes as pods
need them.

**Step 05, storage.** The EBS CSI driver with `gp3` and `gp3-retain` storage classes, EFS
for shared files, volume snapshots, and S3 buckets for Loki's logs and Tempo's traces.

**Step 06, our own Helm chart.** `charts/microservice` deploys order-service in every
environment from one template plus a small per-environment values file; it is linted, unit
tested, and published to ECR from `main`.

**Step 07, metrics.** Prometheus and Grafana (kube-prometheus-stack), highly available in
the cloud, with single sign-on for Grafana.

**Step 08, alerting and SLOs.** Service-level objectives (99.5% of requests without a
server error, 99% under 500 ms) with burn-rate alerts, alerts for missing services, routing
to PagerDuty and Slack, a dead man's switch, unit tests for every rule, a runbook for every
alert, and an alert drill script.

**Step 09, logging.** Grafana Alloy ships every pod's logs to Loki. Logs are JSON, carry
the trace ID, are labelled `edge`, `api` or `server`, and passwords, tokens, cookies and
keys are masked before they're stored. The services log each API call with OpenTelemetry
field names, and the request body only where an environment allows it.

**Step 10, tracing.** The OpenTelemetry Java agent in the services and the OpenTelemetry
web SDK in the browser send traces through a collector (which keeps every error and slow
request and samples the rest) to Tempo. Grafana links metrics, logs and traces together.

**Step 11, synthetic monitoring (partly).** A blackbox exporter checks the home page, order
status and sign-in every 30 seconds like a user would, with alerts, runbooks and an "Is
everything OK?" dashboard; an optional CloudWatch canary checks from outside AWS. The
domain-based checks wait for DNS.

**App fixes.** The services return 401/400/404 for a client's mistakes instead of 500 (a
wrong password used to count as a server error), the frontend builds on Node 24, and
images are pushed only under their commit SHA.

**Checks on every change.** `scripts/validate.sh` renders every environment and checks it
with each tool's own parser (kubeconform, promtool, amtool, Alloy, the OpenTelemetry
Collector, Loki, the blackbox exporter, helm lint and unit tests), in Jenkins inside a
toolbox image whose tools are pinned by checksum.

**Terraform.** The S3 buckets, EBS CSI, EFS, snapshot controller, Karpenter permissions,
immutable ECR tags, IMDSv2 on Jenkins, the chart's ECR repository, the optional canary and
Container Insights, and learning topics 05–11.

---

## Part 2 — The remaining steps, on branch `remaining-roadmap-steps`

All remaining steps are done on one branch per repo, named `remaining-roadmap-steps`, with
at least one commit per step, and pushed to GitHub to be merged in one go. Anything that
costs real money on AWS is added switched off, behind a Terraform variable or by leaving
it out of an environment, and the step's notes say how to turn it on.

Status: ☐ planned · 🔨 in progress · ✅ done (code, docs and checks in the repo; not yet run
on a real cluster unless it says so).

### Phase C — Messaging and event streaming

The services start talking through events instead of only direct calls. When an order is
created, order-service publishes an event to Kafka, and a new notification-service reacts
to it.

| Step | What changes | Status |
|---|---|---|
| 12 Kafka on Kubernetes | Strimzi runs a Kafka cluster declared in Git (`streaming/`): one node in the lab, three controllers and three brokers across zones in dev (staging and prod can opt in). Topics `orders`, `users` and a dead-letter twin for each; one TLS identity per service with only the rights it needs, delivered to each service by the Strimzi Access Operator. order-service has a new `POST /api/orders` that publishes `OrderCreated`; sign-up publishes `UserRegistered`; the new **notification-service** consumes both, retries failures and parks what it can't handle in the dead-letter topic. Strimzi's dashboards, 8 tested alerts with runbooks, an admin pod for the runbooks. Guide: `docs/KAFKA.md`; notes: tf topic 12. | ✅ |
| 13 Kafka ecosystem | Events are now **Avro** with their schemas in a **schema registry** (Apicurio), which refuses a change that would break consumers; notification-service reads each event in the schema it was written with. order-service saves each order and its event in **one MongoDB transaction** (the outbox) and publishes from there, so an order can no longer exist without its event; the lab's MongoDB becomes a replica set for this. In dev, **Kafka Connect** copies every event to an S3 archive kept a year (tf `enable_events_archive`, on in `dev.tfvars`; a few cents a month). A read-only **Kafka UI** (port-forward only), a pod with the Avro console tools for reading and replaying events, 4 more tested alerts with runbooks. Change data capture moved to step 23 (it needs PostgreSQL). Guide: `docs/KAFKA.md`; notes: tf topic 13. | ✅ |
| 14 Amazon MSK | An optional **MSK Serverless** cluster in Terraform (`enable_msk`, off: about $0.75 an hour), with one IAM role per service allowed exactly what its Kafka user is allowed on Strimzi. The services switch to it by configuration only: the chart's `kafka.msk` setting and a matching piece for user-service; the one code change is AWS's sign-in library, with a test per service. A Job creates the topics on MSK. `docs/msk-vs-strimzi.md` gives the switch-over steps and the comparison with numbers: about $95 a month for Strimzi in dev against about $570 for MSK Serverless, and what the difference buys. First `terraform test` in the repo (mocked AWS, no cost). Notes: tf topic 14. | ✅ |
| 15 KEDA | **KEDA** installed as an add-on in every environment. notification-service now scales on its Kafka backlog instead of CPU: none at all when there's nothing to do, up to one per partition when events pile up, and one as a safety net if KEDA can't read the backlog. order-service, in the lab and dev, scales on requests per second as well as CPU (staging and prod keep CPU only, to compare). The "service unavailable" alert no longer fires for a service at zero on purpose; two new alerts for KEDA itself. A setting that slows notification-service down on purpose, for the exercise that shows why CPU-based scaling misses a backlog. Guide: `docs/KEDA.md`; notes: tf topic 15. | ✅ |

**Fixed along the way in step 13:**

- **A damaged event was retried as if the registry were down.** notification-service
  retried any input/output error, and a cut-off record is one; it now retries only when the
  registry can't be reached, and parks a damaged record at once.
- **The dead-letter replay in the runbook would have corrupted events.** It used tools that
  treat values as text; events are binary since this step. The runbook now uses the Avro
  console tools.
- **The outbox's retry delay never reached its 5-minute ceiling** (it stopped at about 4
  minutes); now it does, as documented.
- **Kafka UI and the schema registry answered every pod in the cluster.** Neither has a
  login, and "reachable only through port-forward" was true only of the intent. Network
  policies now limit them: Kafka UI to port-forward, the registry to the services and its
  tools. The lab enforces such policies already; dev now does too (tf
  `enable_network_policy`, pulled forward from step 19).
- **The repo's manifest checker rejected a valid Kafka Connect resource** because it read
  one kind of schema rule too strictly; it is fixed, and still catches real typos.

**Fixed along the way in step 12** (security problems found while adding the order
endpoint, already in the code before this branch):

- **Sign-in tokens could be forged.** user-service signed them with a secret written in its
  source code, active in every environment. It now signs with an RSA key kept in a Secret
  (generated per environment, never in Git or Terraform) and publishes only the public key;
  order-service checks tokens with it. Anyone with the old secret can no longer sign in as
  someone else.
- **The order API was open to anyone.** order-service now requires a valid token, takes the
  user from it, and shows users only their own orders.
- **Terraform deleted the database password on every apply**, and staging and prod never
  asked for it. Credentials now live in their own secrets whose values Terraform never sees
  (set with `tf/scripts/set-secret.sh`).
- Smaller: a token with a bad signature caused a server error instead of a 401; the user ID
  in user-service's call to order-service could reach other paths; event text could forge
  extra lines in a notification.

### Phase D — API gateway, service mesh, network policies

| Step | What changes | Status |
|---|---|---|
| 16 Kong gateway | Kong in DB-less mode takes over routing behind the load balancer, declared in Git, first with Ingress and then with the newer Gateway API (`HTTPRoute`); versioned routes (`/v1`, `/v2`); Kong metrics in Grafana. | ☐ |
| 17 Kong plugins | What a gateway is for: rate limits with shared counters in Redis, API keys with two customer tiers, JWT validation, CORS, header changes, per-route metrics, and a weighted canary route. | ☐ |
| 18 Service mesh | Encrypted, authenticated traffic between services without code changes, retries and timeouts, "only frontend may call order-service" rules (and: only the rules Job may change the schema registry's rules, a gap left open in step 13), and weighted traffic splits; a written opinion on when a mesh is worth it. | ☐ |
| 19 Network policies | Every environment enforces NetworkPolicies (the lab and dev already do since step 13); each namespace denies everything by default and allows only the traffic it needs; pods can no longer reach the EC2 metadata service; database security groups allow only the cluster. | ☐ |

### Phase E — Progressive delivery

| Step | What changes | Status |
|---|---|---|
| 20 Argo Rollouts | A new version gets 10%, then 25%, 50%, 100% of traffic, and Prometheus decides at each step whether it's healthy; a bad version rolls itself back. A blue/green release for a second service. | ☐ |
| 21 Argo Workflows and Events | Kubernetes-native pipelines (build, test, scan, push), S3 for their artifacts, workflows started by a Kafka message or an S3 upload, and a nightly scheduled workflow. | ☐ |
| 22 Feature flags | Unleash for switching features on and off without a deploy: a flag in the frontend, a percentage rollout, and a kill switch around order-service's event publishing. | ☐ |

### Phase F — Data layer

| Step | What changes | Status |
|---|---|---|
| 23 RDS | A production-grade PostgreSQL (optional in Terraform): Multi-AZ, a read replica, TLS required, connection pooling, Performance Insights, password rotation, tighter security groups, and alerts. Plus change data capture, moved here from step 13: Debezium turns the database's changes into Kafka events. | ☐ |
| 24 Database migrations | Versioned schema migrations run automatically before a release, a worked zero-downtime rename (expand and contract), and a check that blocks dangerous migrations. | ☐ |
| 25 Backup and disaster recovery | Versioned Terraform state, AWS Backup for databases and volumes, Velero for whole namespaces, and a recovery runbook with measured restore times. | ☐ |
| 26 DynamoDB and caching | A DynamoDB table with least-privilege access, a Redis cache in front of order lookups with protection against a cache stampede, and cache metrics and alerts. | ☐ |

### Phase G — Security and compliance

| Step | What changes | Status |
|---|---|---|
| 27 Policy as code | Pod Security Admission at `restricted`, and Kyverno rules (no `:latest`, required labels and limits, only our registry, no privileged pods), first reporting, then enforcing; a default NetworkPolicy created in every new namespace; policies tested in CI. | ☐ |
| 28 Supply chain | Every image scanned (Trivy), given a bill of materials (SBOM) and signed (Cosign); the cluster refuses unsigned images; in-cluster vulnerability scanning; Terraform scanners that fail the build. | ☐ |
| 29 Runtime security | Kubernetes API audit logs, Falco detecting shells in containers and other suspicious behaviour with alerts, and a security-incident runbook. | ☐ |
| 30 Vault | An optional Vault: short-lived database passwords generated per service, certificates on demand, and encryption as a service; a comparison with Secrets Manager. | ☐ |
| 31 AWS security services | Optional CloudTrail, GuardDuty, Security Hub, AWS Config rules and IAM Access Analyzer in Terraform, with findings sent to a notification topic. | ☐ |
| 32 Compliance | kube-bench, Kubernetes misconfiguration scans and Prowler running weekly with reports kept in S3, and a `docs/compliance/` set mapping controls to what implements them. | ☐ |

### Phase H — CI/CD maturity and platform engineering

| Step | What changes | Status |
|---|---|---|
| 33 GitHub Actions with OIDC | A reusable GitHub Actions pipeline (test, scan, build, sign, push, bump the tag in gitops) that reaches AWS with no stored keys at all. | ☐ |
| 34 Terraform CI/CD | Linting and security scanning that fail the build, `terraform test` for modules, plan-on-pull-request, nightly drift detection, policy checks on the plan, and cost estimates. | ☐ |
| 35 SonarQube | Code-quality and coverage gates on new code, blocking merges. | ☐ |
| 36 Artifact management | Automatic semantic versions and changelogs from commit messages, the same image digest promoted from dev to prod, and ECR clean-up rules. | ☐ |
| 37 Multi-account and Terragrunt | The environments described once with Terragrunt, deploying through a cross-account role, plus organisation-wide guardrails. | ☐ |
| 38 Backstage and Crossplane | A developer portal listing every service, a "new microservice" template, and cloud resources requested through Kubernetes. | ☐ |

### Phase I — Resilience and cost

| Step | What changes | Status |
|---|---|---|
| 39 Chaos engineering | Chaos Mesh experiments with written hypotheses: killing pods, adding latency, losing a node or a Kafka broker, filling a disk. | ☐ |
| 40 Load testing | k6 tests (smoke, load, spike, soak) run inside the cluster, a post-deploy smoke gate, and a capacity plan. | ☐ |
| 41 Cost optimisation | Budgets and cost reports, cost per namespace and service (OpenCost), right-sizing, spot nodes and night-time scale-down for dev, storage lifecycle rules, and a waste-finding script. | ☐ |
| 42 Multi-region DR | An optional pilot-light second region with replicated data and a regional failover runbook. | ☐ |

### Phase J — Capstone

| Step | What changes | Status |
|---|---|---|
| 43 Capstone | Updated architecture document and diagrams, a complete runbook library, on-call guide, decision records for every "X or Y" choice, an end-to-end demo script, and a rebuild-from-zero guide. | ☐ |

### Last — DNS and TLS (step 03's remainder)

| Step | What changes | Status |
|---|---|---|
| 03 DNS and TLS | A Route 53 zone, an ACM certificate, ExternalDNS and cert-manager, the public HTTPS checks and certificate-expiry alerts from step 11, all switched on by setting the domain. | ☐ |
