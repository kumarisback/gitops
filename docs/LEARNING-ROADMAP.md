# DevOps Learning Roadmap — from these two repos to enterprise level

Built specifically around **your** `tf` + `gitops` repos. Every step is a branch that
builds on the previous one, so your git history becomes a record of what you learned when.

**How to read this:** each step has a *Design* section (the decisions a senior engineer
thinks about before touching a keyboard) and an *Implement* section (what to actually do).
Do both. The design thinking is what separates "I followed a tutorial" from "I can run
this in production."

---

## Part 0 — Before you start

### 0.1 What you already have (don't re-learn this)

Your repos already cover, and cover reasonably well:

| Area | What's already there |
|---|---|
| **Terraform** | Reusable modules, layered root modules, remote S3 state + locking, per-env tfvars, `data` sources, `for_each`/`count`/`dynamic` blocks, module outputs, remote state reads |
| **AWS networking** | VPC, 3-tier subnets (public/private-app/private-data), IGW, NAT (single + per-AZ), route tables, VPC peering |
| **AWS compute** | EKS cluster, managed node groups, launch templates, IMDSv2, EKS access entries |
| **AWS identity** | IAM roles/policies/instance profiles, trust policies, OIDC provider, IRSA, service-linked roles |
| **AWS data/other** | ElastiCache Redis, ECR + lifecycle policies, Secrets Manager, SSM Parameter Store |
| **Kubernetes** | Deployments, Services (ClusterIP/LoadBalancer), Namespaces, resource requests/limits |
| **GitOps** | ArgoCD, App-of-Apps, sync policies (prune/selfHeal), finalizers & cascade deletion, Kustomize bases + overlays |
| **Platform add-ons** | External Secrets Operator, AWS Load Balancer Controller |
| **CI** | Jenkins declarative pipelines, parameters, stages, manual approval gates, Checkov scanning |
| **Ops access** | SSM Session Manager, port forwarding, private-only cluster access |

That's genuinely a lot. The roadmap below assumes all of it.

### 0.2 Foundations to shore up first (study, no branch)

You said you're new to this — these are the things that will bite you constantly if
shaky. Don't spend months here, but don't skip it either. **~2 weeks.**

**Linux & processes**
- `systemd` (why `systemctl enable` ≠ `start`), reading `journalctl -u <svc>`
- Processes, signals (`SIGTERM` vs `SIGKILL` — this directly explains K8s pod shutdown)
- File permissions, users/groups (explains the `usermod -aG docker jenkins` in your Jenkins user_data)
- cgroups & namespaces — *this is literally what a container is*
- **Exercise:** SSM into your Jenkins box, find why a service failed using only `journalctl`

**Networking**
- CIDR math — be able to answer "how many IPs in `10.10.1.0/24`?" instantly. Your VPC design depends on it
- DNS resolution order, what an A vs CNAME record is
- TCP handshake, ports, NAT (you have a NAT Gateway — know what it actually does)
- TLS handshake, what a certificate chain is, why self-signed warns
- **Exercise:** trace the full path of a packet from your laptop → `frontend` LoadBalancer → pod → Redis. Name every hop.

**Docker (deeper than you need for these repos)**
- Multi-stage builds, layer caching, `.dockerignore`
- Distroless / Alpine / scratch base images and their tradeoffs
- Why `latest` is dangerous (your `apps/dev` uses `newTag: "latest"` — understand exactly why that's a problem)
- BuildKit, build args vs env vars, non-root users
- **Exercise:** take any service, get its image under 100MB with a multi-stage build

**Kubernetes core objects you haven't touched yet**
- StatefulSet, DaemonSet, Job, CronJob, init containers, sidecars
- ConfigMap vs Secret, projected volumes
- ResourceQuota, LimitRange, PriorityClass
- **Exercise:** for each, write one manifest and apply it to your dev cluster by hand (`kubectl apply`), then delete it. Understand it *before* GitOps hides it from you.

**Git beyond commit/push**
- `rebase -i`, `cherry-pick`, `bisect`, `reflog`, `stash`
- Trunk-based development vs GitFlow
- **Why:** you're about to create 40+ branches. Get comfortable.

### 0.3 Cost discipline — read this before you spin anything up

You're learning in a **real AWS account with real billing**. This roadmap could cost
$300+/month if you leave everything running. Rules:

1. **Destroy at the end of every session.** Your pipeline already has a `destroy` action — use it. `terraform destroy` is a learning tool, not a failure.
2. **Only run `dev`.** Never apply `staging`/`prod` unless a step specifically teaches multi-env. Two extra clusters = 3× the cost.
3. **Single NAT Gateway** for learning (~$32/mo each, and they bill even when idle). Keep `single_nat_gateway = true` except in the one step where you're specifically learning HA NAT.
4. **Use Spot** for node groups (`node_capacity_type = "SPOT"` — you already have the variable). ~70% cheaper. Perfect for learning.
5. **Smallest instances that work.** `t3.small`/`t3.medium`. Kafka and ELK will need more — that's exactly why those steps are timeboxed.
6. **Set an AWS Budget alert at $50** *today*, before step 01. Console → Billing → Budgets.
7. **`kubectl get svc -A | grep LoadBalancer` before destroying.** Every LoadBalancer Service = a real ELB = real money, and (as you learned the hard way) can block VPC teardown.
8. **The expensive steps** are flagged with 💰 below. For those: build it, verify it, screenshot it, destroy it same day.

### 0.4 How the branch workflow works

Each step = one branch, in **both repos where relevant**, using the same name:

```bash
# In tf/ and/or gitops/
git checkout main && git pull
git checkout -b 07-prometheus-grafana
# ... do the work, commit as you go ...
git push -u origin 07-prometheus-grafana
```

**Critical gotcha for gitops branches:** ArgoCD syncs whatever
`argocd_gitops_repo_revision` points at — currently `"HEAD"` (= `main`). So a branch in
`gitops` is *invisible* to ArgoCD until you either:

- **(recommended)** point it at your branch while working:
  ```hcl
  # environments/app-cluster/dev.tfvars
  argocd_gitops_repo_revision = "07-prometheus-grafana"
  ```
  re-apply Layer 2, verify, then merge to `main` and set it back to `"HEAD"`.
- or merge to `main` immediately and let ArgoCD pick it up (faster, but you lose the "verify before merge" habit that matters in real teams).

**Merge as you finish each step** so the next builds on it. Keep the numbered branches
pushed — that's your learning record and, honestly, a decent portfolio.

**Per-step discipline:** each branch should end with (a) it works, (b) you wrote 5+ lines
in a `NOTES.md` on that branch about what broke and why, (c) you can explain it out loud
without notes. If you can't do (c), don't move on.

---

## Progress tracker

✅ done · 🟡 partly done · ☐ not started. Last reviewed against the `tf`, `gitops` and
app repos on 2026-10-05 (updated after completing steps 01–10; steps 06 and 11 on 2026-10-07, steps 12–13 on 2026-10-26, step 14 on 2026-10-30); the `tf/learning-topics` notes cover the steps marked done or partly done.

| # | Branch | Phase | 💰 | Done | Notes |
|---|---|---|---|---|---|
| 01 | `01-k8s-rbac` | A: Close gaps |  | ✅ | Incl. quotas/limits for every cloud namespace, sized to the HPAs (tf topic 03, 05) |
| 02 | `02-production-workloads` | A |  | ✅ | Images pinned to commit-SHA tags everywhere; ECR tags immutable (tf topic 04) |
| 03 | `03-ingress-tls-dns` | A |  | 🟡 | Deferred to the end (no domain yet). Done: one shared ALB with path routing, frontend on ClusterIP. Pending: domain + Route53 zone, ACM cert, ExternalDNS, cert-manager |
| 04 | `04-autoscaling` | A |  | ✅ | HPA, VPA (recommend-only), Karpenter 1.14 / v1 / AL2023; Cluster Autoscaler skipped for Karpenter. To run on dev: load + spot-interruption tests (tf topic 05) |
| 05 | `05-storage-statefulsets` | A |  | ✅ | EBS CSI + gp3/gp3-retain, EFS, snapshots, StatefulSet, S3 for Loki/Tempo. To run on dev: the topic's exercises (tf topic 06) |
| 06 | `06-helm-authoring` | A |  | ✅ | `charts/microservice` + `charts/common` library; order-service on Helm in every env, frontend/user-service stay on Kustomize; lint, unit tests, render in validate/Jenkins; published to ECR from main. No Ingress in the chart (one shared ALB Ingress). To run on dev: install from ECR + `helm rollback`, ArgoCD Synced (tf topic 10) |
| 07 | `07-prometheus-grafana` | B: Observability | 💰 | ✅ | tf topic 07 |
| 08 | `08-alerting-slo` | B |  | ✅ | Built, unit-tested, with scripts/alert-drill.sh. To do: real Slack/PagerDuty keys in Secrets Manager (tf topic 07) |
| 09 | `09-elk-logging` | B | 💰💰 | ✅ | Done with Loki instead of ELK (decision 2026-10-05): JSON logs, correlation, masking, edge/api/server (tf topic 08) |
| 10 | `10-tracing-otel` | B | 💰 | ✅ | The 2s-delay exercise is optional practice (tf topic 09) |
| 11 | `11-synthetic-blackbox` | B |  | 🟡 | Done: blackbox exporter, Probes per service (lab also through Traefik), alerts with unit tests and runbooks, "Is everything OK?" dashboard; tf: Synthetics canary + Container Insights (both off by default). Waits for the domain (step 03): public-URL and TLS probes, DNS checks. To run on dev: enable the canary, the SG/DNS verify tests (tf topic 11) |
| 12 | `12-kafka-strimzi` | C: Streaming | 💰💰 | ✅ | Strimzi 1.3 / Kafka 4.3 (KRaft), cluster in `streaming/` (lab 1 node; dev 3+3 across zones; staging/prod opt-in), TLS client auth + ACLs via KafkaAccess, notification-service consumer with retries + DLQ, 8 alerts. Also fixed: forgeable sign-in tokens (RS256 + JWKS now). To run on dev: broker-kill and lag exercises (tf topic 12) |
| 13 | `13-kafka-ecosystem` | C | 💰💰 | ✅ | Apicurio schema registry (Avro, `BACKWARD`), transactional outbox in order-service (lab MongoDB as a replica set), Kafka Connect + Aiven S3 sink archiving `orders`/`users` (dev; tf `enable_events_archive`), read-only Kafka UI, Avro console pod, 4 more alerts. CDC (Debezium) moved to step 23. To run on dev: archive and outbox exercises (tf topic 13) |
| 14 | `14-msk-managed` | C | 💰💰 | ✅ | `modules/msk` (MSK Serverless, IAM auth, `enable_msk` off) + IRSA roles mirroring the KafkaUser ACLs; chart 0.3.0 `kafka.msk`, `apps/components/kafka-msk`, `msk/topics-job.yaml`; `docs/msk-vs-strimzi.md` (cost, auth, ops). Module `terraform test` with a mocked provider. To run: the afternoon switch-over (tf topic 14) |
| 15 | `15-keda-autoscaling` | C |  | ☐ |  |
| 16 | `16-kong-gateway` | D: Gateway/Mesh |  | ☐ |  |
| 17 | `17-kong-plugins` | D |  | ☐ |  |
| 18 | `18-service-mesh` | D | 💰 | ☐ | Also: restrict the schema registry's admin API to the rules Job (open since step 13) |
| 19 | `19-network-policies` | D |  | ☐ | Enforcement already on in the lab (KinD ≥ 0.24) and dev (tf `enable_network_policy`, step 13): policies for Kafka UI, the registry, blackbox exporter |
| 20 | `20-argo-rollouts` | E: Delivery |  | ☐ |  |
| 21 | `21-argo-workflows-events` | E |  | ☐ |  |
| 22 | `22-feature-flags` | E |  | ☐ |  |
| 23 | `23-rds-production` | F: Data | 💰 | ☐ | RDS module exists in tf but `enable_rds = false`; also takes step 13's CDC (Debezium) |
| 24 | `24-db-migrations` | F |  | ☐ |  |
| 25 | `25-backup-dr` | F |  | ☐ |  |
| 26 | `26-dynamodb-caching` | F |  | ☐ |  |
| 27 | `27-pod-security-policy` | G: Security |  | ☐ |  |
| 28 | `28-supply-chain` | G |  | ☐ |  |
| 29 | `29-runtime-security` | G |  | ☐ |  |
| 30 | `30-vault` | G | 💰 | ☐ |  |
| 31 | `31-aws-security-services` | G | 💰 | ☐ |  |
| 32 | `32-compliance-benchmarks` | G |  | ☐ |  |
| 33 | `33-github-actions-oidc` | H: CI/CD |  | ☐ |  |
| 34 | `34-terraform-cicd` | H |  | ☐ | Starting point: the Jenkins plan/apply pipeline with Checkov |
| 35 | `35-sonarqube-gates` | H |  | ☐ |  |
| 36 | `36-artifact-management` | H |  | ☐ |  |
| 37 | `37-multi-account-terragrunt` | H | 💰 | ☐ |  |
| 38 | `38-backstage-crossplane` | H | 💰 | ☐ |  |
| 39 | `39-chaos-engineering` | I: Resilience |  | ☐ |  |
| 40 | `40-load-testing` | I |  | ☐ |  |
| 41 | `41-cost-optimization` | I |  | ☐ |  |
| 42 | `42-multi-region-dr` | I | 💰💰💰 | ☐ |  |
| 43 | `43-capstone` | J |  | ☐ |  |

Realistic pace as a beginner: **9–14 months** at 8–10 hrs/week. Don't rush. Steps
01–11 alone will make you employable as a junior/mid DevOps engineer.

---

# PHASE A — Close the gaps in what you already have

Start here, not with Kafka. These are things your current setup is *missing* or *has but
doesn't use*, and everything later depends on them.

## 01 — `01-k8s-rbac`: In-cluster RBAC and ServiceAccounts

**Why:** You have AWS-side access control (EKS access entries, IRSA), but zero
Kubernetes-side RBAC. Right now anything in your cluster runs with the `default`
ServiceAccount and whatever that can do. This is the #1 gap.

**Design first**
- Understand the two *separate* auth layers: AWS IAM gets you *to* the cluster API; K8s RBAC decides what you can do *inside* it. Your `eks_admin_users` handles the first, nothing handles the second.
- Who needs what? Sketch roles: `developer` (read pods/logs in own namespace), `ci-deployer` (write Deployments, no Secrets), `sre` (cluster-wide read + exec), `admin`.
- Namespace-scoped (`Role`) vs cluster-wide (`ClusterRole`) — default to namespace-scoped.
- Why `ServiceAccount` ≠ user: SAs are for *workloads*, users/groups for *humans*.

**Implement**
1. In `gitops/apps/base/<each-service>/`, add a dedicated `serviceaccount.yaml` per service and reference it in the Deployment's `spec.template.spec.serviceAccountName`. Stop using `default`.
2. Set `automountServiceAccountToken: false` on services that don't call the K8s API (all three of yours). Understand why this matters.
3. Create `gitops/platform/rbac/` with `ClusterRole`s for `developer-readonly` and `sre`.
4. Bind an IAM role/user to a K8s group via EKS access entries in `modules/eks/main.tf` — add a variable for non-admin access entries with `AmazonEKSViewPolicy` instead of `ClusterAdminPolicy`.
5. Add `ResourceQuota` and `LimitRange` per namespace in `gitops/apps/<env>/`.

**Verify**
- `kubectl auth can-i --list --as=system:serviceaccount:development:frontend`
- Assume the read-only role, try `kubectl delete pod` — should be denied
- `kubectl describe quota -n development`

**Common mistakes:** binding `cluster-admin` "temporarily"; forgetting that a
`RoleBinding` in namespace A can reference a `ClusterRole` but only grants within A;
assuming IRSA replaces RBAC (they're orthogonal).

**Read:** K8s RBAC docs; EKS access entries docs. **~1 week.**

---

## 02 — `02-production-workloads`: Make your Deployments actually production-grade

**Why:** Your `frontend` Deployment has replicas and resource limits but no probes, no
disruption budget, no anti-affinity, no graceful shutdown. It would fail a real
production review.

**Design first**
- Three probe types and why each exists: `startupProbe` (slow boot), `readinessProbe` (remove from load balancing), `livenessProbe` (restart me). Getting liveness wrong causes restart loops — think about what "unhealthy enough to restart" really means.
- Requests vs limits, and what CPU throttling vs OOMKill feel like. Why `requests == limits` for memory is often right, and why CPU limits are controversial.
- `PodDisruptionBudget`: how many pods can be down during a *voluntary* disruption (node drain, upgrade)? With 2 replicas, `minAvailable: 1`.
- Spreading: `podAntiAffinity` vs `topologySpreadConstraints` — you have 2 AZs; make sure both replicas aren't on one node.
- Graceful shutdown: `terminationGracePeriodSeconds`, `preStop` hook, and why your app must handle `SIGTERM`.

**Implement**
1. Add startup/readiness/liveness probes to all three services in `gitops/apps/base/*/deployment.yaml`.
2. Add `PodDisruptionBudget` per service.
3. Add `topologySpreadConstraints` across `topology.kubernetes.io/zone`.
4. Add `preStop` sleep hook + explicit `terminationGracePeriodSeconds`.
5. Set `securityContext`: `runAsNonRoot`, `readOnlyRootFilesystem`, drop all capabilities, `allowPrivilegeEscalation: false`.
6. Pin image tags properly — replace `newTag: "latest"` in `apps/dev/kustomization.yaml` with a real version or digest.

**Verify**
- `kubectl drain` a node — traffic should not drop (watch with a `curl` loop against the LB)
- `kubectl get pods -o wide` — replicas on different nodes/AZs
- Break the readiness endpoint deliberately; confirm the pod leaves the Service's endpoints (`kubectl get endpoints`) but does *not* restart

**Common mistakes:** liveness probe pointing at a dependency (Redis down → all your pods
restart forever); readiness with too-short `initialDelaySeconds`; `readOnlyRootFilesystem`
without an `emptyDir` for temp files.

**~1 week.**

---

## 03 — `03-ingress-tls-dns`: Ingress, real domains, real TLS

**Why:** You *installed* the AWS Load Balancer Controller in step `02-services` but never
created a single `Ingress` — it's doing nothing. Also, `frontend` uses a raw
`type: LoadBalancer`, which means one ELB per service (expensive, no path routing, no TLS).

**Design first**
- `LoadBalancer` Service (one NLB/CLB per service, L4) vs `Ingress` + ALB (one ALB, many services, L7 path/host routing, TLS termination). When would you still choose the former?
- `IngressClass`, and the `alb.ingress.kubernetes.io/group.name` annotation to share one ALB across Ingresses in different namespaces.
- Certificate strategy: ACM (AWS-managed, free, auto-renews, ALB-integrated) vs cert-manager + Let's Encrypt (portable, works in-cluster, needed for mesh/mTLS later). Do both — they teach different things.
- DNS: manual Route53 records vs **ExternalDNS** (controller that creates records from your Ingress annotations). Understand why the automated version is what enterprises use.
- `internet-facing` vs `internal` scheme, and which of your services should be which.

**Implement**
1. Register a cheap real domain (~$12/yr on Route53) — you genuinely need one for TLS to be real. Create a hosted zone in Terraform (`modules/dns/`).
2. Convert `frontend` from `type: LoadBalancer` to `ClusterIP` + an `Ingress` with ALB annotations. **Remember your destroy lesson:** the ALB is still AWS-side, still needs the ArgoCD finalizer to clean up.
3. Request an ACM certificate in Terraform with DNS validation; wire its ARN into the Ingress annotation.
4. Install ExternalDNS via Helm in `02-services`, with an IRSA role scoped to your hosted zone only (reuse the `irsa_roles` map you already have — this is exactly what it's for).
5. Install cert-manager, create a `ClusterIssuer` for Let's Encrypt (DNS-01 via Route53), and issue one cert that way to compare.
6. Add path-based routing: `/` → frontend, `/api/orders` → order-service, `/api/users` → user-service, all on one ALB.

**Verify**
- `https://yourdomain.com` loads with a valid cert (no browser warning)
- `dig yourdomain.com` returns the ALB — and the record was created by ExternalDNS, not you
- Only *one* ALB exists in the console for all three services
- Delete the Ingress → ExternalDNS removes the DNS record automatically

**Common mistakes:** forgetting `kubernetes.io/role/elb` subnet tags (ALB can't find
subnets); ACM cert in the wrong region; ExternalDNS IRSA scoped to `*` instead of your
zone; leaving the old LoadBalancer Service around and paying for two load balancers.

**~2 weeks.** This is the highest-value step in Phase A.

---

## 04 — `04-autoscaling`: HPA, Cluster Autoscaler, then Karpenter

**Design first**
- Three independent axes: **HPA** (more pods), **VPA** (bigger pods), **Cluster Autoscaler/Karpenter** (more nodes). They interact — HPA can't help if there's no node capacity.
- HPA on CPU is the starting point but rarely right. Custom metrics (requests/sec, queue depth) matter more — this foreshadows KEDA in step 15.
- Cluster Autoscaler (works off ASGs, node-group-shaped) vs **Karpenter** (provisions right-sized nodes directly, much faster, AWS's current recommendation). Know both; Karpenter is where the industry is going.
- Scale-down is the hard part: `PodDisruptionBudget` (step 02) is what makes it safe. Understand `--scale-down-utilization-threshold` and consolidation.

**Implement**
1. Install `metrics-server` (via Helm in `02-services`).
2. Add HPA to `frontend`: min 2, max 10, target 70% CPU.
3. Install Cluster Autoscaler with IRSA; tag your node group ASG appropriately. Set `node_min_capacity`/`node_max_capacity` sensibly.
4. Load-test it: `kubectl run -it --rm load --image=busybox -- /bin/sh -c "while true; do wget -q -O- http://frontend; done"`, watch `kubectl get hpa -w` and `kubectl get nodes -w`.
5. **Then replace Cluster Autoscaler with Karpenter**: install its CRDs, create a `NodePool` + `EC2NodeClass`, mix on-demand and spot. Compare scale-up time (Karpenter should be dramatically faster).
6. Try VPA in recommendation-only mode; compare its suggestions to the limits you set in step 02.

**Verify**
- Scale up under load, scale back down when idle (watch the full cycle)
- Karpenter provisions a node in <60s vs Cluster Autoscaler's several minutes
- Spot interruption handling: a spot node gets reclaimed, pods reschedule, no downtime

**Common mistakes:** HPA with no resource `requests` set (it has nothing to compute % against); autoscaler IRSA missing ASG permissions; forgetting Karpenter needs its own subnet/SG discovery tags.

**~2 weeks.**

---

## 05 — `05-storage-statefulsets`: Persistent storage and stateful workloads

**Why:** Everything you run today is stateless. Kafka, Elasticsearch, and Prometheus (steps
07–13) are all stateful — you need this first.

**Design first**
- `PersistentVolume` / `PersistentVolumeClaim` / `StorageClass` and dynamic provisioning.
- EBS (block, single-AZ, one pod at a time, fast) vs EFS (NFS, multi-AZ, many pods, slower). Which does a database want? Which does a shared upload directory want?
- `StatefulSet` vs `Deployment`: stable network identity, ordered rollout, per-pod PVC via `volumeClaimTemplates`. Why Kafka fundamentally needs this.
- **The AZ trap:** an EBS volume lives in one AZ, so its pod can only schedule there. `WaitForFirstConsumer` binding mode exists for exactly this reason.
- `reclaimPolicy: Retain` vs `Delete` — a `Delete` default has destroyed real production data at real companies.

**Implement**
1. Install the **EBS CSI driver** as an EKS addon (`aws_eks_addon` in Terraform) with IRSA.
2. Create `StorageClass`es: `gp3-retain` (`Retain`, `WaitForFirstConsumer`) and `gp3-delete`. Understand why `gp3` > `gp2`.
3. Install the **EFS CSI driver** + an EFS filesystem in Terraform with mount targets per AZ.
4. Deploy a practice `StatefulSet` (a 3-replica PostgreSQL, or just nginx writing timestamps) with `volumeClaimTemplates`.
5. Kill a pod — confirm it comes back with the *same* name and *same* data.
6. Take a volume snapshot: install the CSI snapshotter, create a `VolumeSnapshot`, delete the StatefulSet, restore from the snapshot.

**Verify**
- `kubectl get pv,pvc` shows bound volumes; the EBS volumes are visible in the EC2 console
- Data survives pod deletion; pod names are stable (`web-0`, `web-1`)
- Restore-from-snapshot actually returns your data

**Common mistakes:** default `StorageClass` with `reclaimPolicy: Delete` on something that
matters; EBS PVC stuck `Pending` because the pod is scheduled in an AZ with no volume;
expecting `ReadWriteMany` from EBS (it can't).

**~1.5 weeks.**

---

## 06 — `06-helm-authoring`: Write your own chart (don't just install other people's)

**Why:** You *consume* Helm charts (ArgoCD, ESO, LB Controller) but have never *written*
one. You use Kustomize for your apps. Enterprises use both, and you need to know when each
wins and how to author both.

**Design first**
- Kustomize (patch/overlay, no templating, K8s-native) vs Helm (templating, packaging, versioning, dependencies, rollback). Why your current app setup is fine with Kustomize, and where it breaks down.
- Chart anatomy: `Chart.yaml`, `values.yaml`, `templates/`, `_helpers.tpl`, `NOTES.txt`.
- `values.yaml` design is API design — what should be configurable? Overly-flexible charts are as bad as rigid ones.
- Chart repos: OCI registries (ECR can host charts! you already have ECR) vs ChartMuseum.
- Chart testing: `helm lint`, `helm template`, `helm unittest`, `ct` (chart-testing).

**Implement**
1. Create `charts/microservice/` — one generic chart that can deploy any of your three services (Deployment, Service, ServiceAccount, HPA, PDB, Ingress, all toggleable).
2. Use `_helpers.tpl` for consistent labels (follow the `app.kubernetes.io/*` recommended label set).
3. Add `values-dev.yaml` / `values-staging.yaml` / `values-prod.yaml`.
4. Add a `helm unittest` suite and `helm lint` to your Jenkins pipeline.
5. Package it and push to ECR as an OCI artifact; install *from* ECR.
6. Point one ArgoCD Application at your chart instead of Kustomize — keep the other two on Kustomize so you can compare them side by side.
7. Add a chart dependency (e.g. bitnami/redis as a subchart) to learn `Chart.lock` and `helm dependency update`.

**Verify**
- `helm template` output is valid for all three envs
- Chart installs from ECR OCI; `helm rollback` actually reverts
- ArgoCD shows the Helm-based app as Synced/Healthy

**Common mistakes:** un-quoted template values breaking YAML; indentation bugs from
`nindent` vs `indent`; hardcoding namespaces; forgetting `helm upgrade --install` semantics.

**~1.5 weeks.**

---

# PHASE B — Observability

You cannot operate what you cannot see. This phase is arguably more important than
everything after it.

## 07 — `07-prometheus-grafana`: Metrics 💰

**Design first**
- Pull (Prometheus scrapes you) vs push (you send to a collector). Why Prometheus chose pull and what that implies for short-lived jobs (→ Pushgateway).
- Metric types: counter, gauge, histogram, summary. When each applies. Why histograms are how you get percentiles — and why averaging percentiles is mathematically wrong.
- Cardinality: the single biggest way to blow up a metrics system. A label with user IDs in it will kill your Prometheus. Learn this *before* you cause it.
- `ServiceMonitor`/`PodMonitor` CRDs (Prometheus Operator) vs raw scrape configs.
- Retention & storage: local TSDB (short) vs remote write to Thanos/Mimir/AMP (long). Why 15 days local is a common default.
- **The four golden signals**: latency, traffic, errors, saturation. Also know RED (Rate/Errors/Duration) and USE (Utilization/Saturation/Errors).

**Implement**
1. Install `kube-prometheus-stack` via Helm (in `02-services` or as an ArgoCD app under `platform/` — decide which and justify it).
2. Persist Prometheus with the `gp3-retain` StorageClass from step 05.
3. Instrument one of your services with a Prometheus client library — expose `/metrics` with a request counter and a latency histogram.
4. Add a `ServiceMonitor` for it; confirm the target appears in Prometheus.
5. Write PromQL by hand (don't copy dashboards): request rate, error rate, p50/p95/p99 latency, pod restarts, node CPU saturation, PVC fill %.
6. Build a Grafana dashboard from those queries. Then import the standard K8s dashboards and compare.
7. Provision Grafana dashboards as code (ConfigMaps + the sidecar), not clicked-in-UI.
8. Access Grafana via `kubectl port-forward` (keep it private, like ArgoCD).

**Verify**
- Your custom app metric graphs correctly in Grafana
- Kill a pod → see it in metrics within the scrape interval
- Dashboards survive a Grafana pod restart (because they're code)

**Common mistakes:** no persistence (lose all metrics on restart); scraping everything and
OOMing Prometheus; high-cardinality labels; dashboards that exist only in the UI.

**Cost note:** Prometheus + Grafana want ~4GB RAM. Bump your node to `t3.large` for this
phase, or scale to 1 replica of everything else. **~2 weeks.**

---

## 08 — `08-alerting-slo`: Alerts that don't wake you for nothing

**Design first**
- Symptom-based vs cause-based alerting. Alert on "users are getting errors," not "CPU is 90%." Why: nobody cares about CPU if the service is fine.
- **SLI/SLO/SLA** and error budgets. Define an SLO for `frontend` (e.g. 99.5% of requests succeed in <300ms over 30 days). Compute the error budget. This is the single most valuable ops concept in this whole roadmap.
- Multi-window multi-burn-rate alerting (fast burn → page; slow burn → ticket). Read the Google SRE workbook chapter.
- Alert fatigue is a real failure mode. Every alert must be actionable and have a runbook.
- Routing: severity → destination (page vs Slack vs ticket), grouping, inhibition, silences.

**Implement**
1. Write `PrometheusRule` CRDs: recording rules for your SLIs, alerting rules for burn rates.
2. Configure Alertmanager: routes by severity, grouping, inhibition (don't alert on pods when the whole node is down).
3. Wire a free Slack webhook (or Discord/email) as a receiver.
4. Build an SLO dashboard in Grafana: error budget remaining, burn rate.
5. Write an actual runbook (`docs/runbooks/frontend-high-error-rate.md`) and link it from the alert annotation.
6. **Deliberately break things** and confirm the right alert fires with the right severity: scale to 0, break the DB connection, fill a PVC, exhaust CPU.
7. Add "dead man's switch" (`Watchdog`) — an alert that fires *constantly* so you know the alerting pipeline itself is alive.

**Verify**
- Break something → Slack message within 2 min, with a runbook link
- Fix it → resolution notification
- The `Watchdog` alert is firing (proving the pipeline works)

**~1.5 weeks.**

---

## 09 — `09-elk-logging`: Centralized logging (ELK / EFK) 💰💰

**Design first**
- The stack, and who does what: **Elasticsearch** (store/search), **Kibana** (UI), and a shipper — **Logstash** (heavy, powerful transforms), **Fluentd** (CNCF, plugin-rich), or **Fluent Bit** (tiny, fast, C — the current default for K8s). Know why Fluent Bit usually wins as a DaemonSet.
- Where do container logs actually live? `/var/log/containers/*.log` on the node → why the shipper is a `DaemonSet` with hostPath mounts.
- Structured (JSON) logging vs plain text, and why the former is non-negotiable at scale.
- Index strategy: daily indices, ILM (hot/warm/cold/delete), shard sizing. Logs will eat your disk — plan retention *first*.
- **Logs vs metrics vs traces**: three pillars, different questions. Logs are the most expensive per byte. Know when to use each.
- Managed alternative: **AWS OpenSearch** (fork of ES) or CloudWatch Logs. Self-hosting ES on K8s is a genuine operational burden — understand the tradeoff.
- Sensitive data: logs leak PII/secrets. Redaction/masking in the pipeline.

**Implement**
1. Convert one service to structured JSON logging with a correlation/request ID.
2. Install **ECK** (Elastic Cloud on Kubernetes operator) — 3-node Elasticsearch StatefulSet on `gp3-retain`, plus Kibana.
3. Install **Fluent Bit** as a DaemonSet: parse container logs, enrich with K8s metadata (namespace/pod/labels), ship to Elasticsearch.
4. Set up ILM: hot 2 days → warm 5 → delete at 7. (Learning cluster — keep it small.)
5. Build Kibana: index patterns, Discover queries, a dashboard (errors over time, top error messages, log volume by service).
6. Add a redaction filter in Fluent Bit that masks anything looking like a token or email.
7. Trace one request end-to-end using its correlation ID across all three services.
8. **Then** do the same with managed OpenSearch via Terraform and write up the comparison (cost, ops burden, features).
9. Also install **Loki** + the Grafana datasource and compare: much cheaper, label-based instead of full-text. Form an opinion on when you'd pick which.

**Verify**
- Logs from all pods appear in Kibana within seconds, with K8s metadata attached
- You can find all logs for one request across services via correlation ID
- ILM actually deletes old indices
- Secrets are masked

**Cost note:** 💰💰 A 3-node ES cluster is the most expensive thing in Phase B. Build it,
learn it, screenshot your dashboards, **destroy it the same week**. Consider a single-node
ES if budget is tight. **~2.5 weeks.**

---

## 10 — `10-tracing-otel`: Distributed tracing 💰

**Design first**
- Why logs and metrics aren't enough: "which of the 6 services in this request was slow?"
- Spans, traces, trace context propagation (W3C `traceparent` header), parent/child relationships.
- **OpenTelemetry** as the vendor-neutral standard: SDK (in-app) + Collector (pipeline). Why OTel won and why you should never instrument against a vendor SDK directly again.
- Backends: Jaeger, Grafana Tempo, AWS X-Ray. Tempo integrates with your Grafana from step 07.
- **Sampling** — you cannot store every trace at scale. Head-based vs tail-based; how tail-based lets you keep 100% of *error* traces.
- Correlating traces ↔ logs ↔ metrics via trace/span IDs (this is "observability" as opposed to just monitoring).

**Implement**
1. Instrument all three services with the OTel SDK — auto-instrumentation first, then one manual custom span.
2. Make `frontend` actually call `order-service` and `user-service` (you need a real call chain to have anything to trace). Propagate context.
3. Install the **OTel Collector** (Deployment or DaemonSet — decide which and why) with receivers/processors/exporters configured.
4. Install **Grafana Tempo** with S3 backend storage (via Terraform bucket + IRSA).
5. View a trace waterfall; find the slow span. Add an artificial 2s delay in one service and *see* it.
6. Add trace IDs to your log lines; jump from a Kibana/Loki log line to the trace in Tempo.
7. Configure tail-based sampling: keep 100% of errors, 10% of successes.

**Verify**
- A single request produces one trace spanning all three services
- You can pinpoint the slow service from the waterfall
- Log → trace navigation works

**~2 weeks.**

---

## 11 — `11-synthetic-blackbox`: Outside-in monitoring

**Design first**
- Blackbox (probe from outside, does the user experience work?) vs whitebox (internal metrics). You need both — internal metrics can be green while DNS is broken.
- Where to probe *from* matters: inside the cluster misses ingress/DNS/cert problems entirely.
- Certificate expiry monitoring — a genuinely common outage cause.

**Implement**
1. Install `blackbox_exporter`; probe your public endpoints (HTTP 200, TLS expiry, DNS resolution).
2. Alert on: endpoint down, cert expiring in <21 days, TLS handshake failure, DNS failure.
3. Add CloudWatch Synthetics canaries via Terraform (probes from *outside* AWS's view of your cluster) and compare.
4. Enable **CloudWatch Container Insights** on EKS; compare it to your Prometheus setup — form an opinion on managed vs self-hosted.
5. Build a single-pane "is everything OK?" Grafana dashboard combining blackbox, SLOs, and infra health.

**Verify** Delete a DNS record → alert fires. Block the ALB SG → alert fires.

**~1 week.**

---

# PHASE C — Messaging & event streaming

## 12 — `12-kafka-strimzi`: Kafka on Kubernetes 💰💰

**Design first**
- Why Kafka and not a queue: durable, replayable, ordered-per-partition log; multiple independent consumers; decoupling. When you'd use SQS/RabbitMQ instead (task queues, no replay needed).
- Core concepts, properly: topic, **partition** (the unit of parallelism *and* ordering), offset, consumer group, replication factor, ISR (in-sync replicas), leader/follower, `min.insync.replicas`, retention (time vs size vs compacted).
- **Partition count is a design decision you can't easily undo** — it caps consumer parallelism and determines ordering guarantees. Think hard here.
- Delivery semantics: at-most-once / at-least-once / exactly-once, and what idempotent producers + transactions actually give you.
- KRaft vs ZooKeeper (KRaft is the present; know ZK existed and why it was dropped).
- Why Kafka on K8s needs StatefulSets, per-broker PVs, rack awareness (`broker.rack` → your AZs), and PDBs — everything from step 05 and 02.

**Implement**
1. Install the **Strimzi** operator (Helm, in `02-services` or as an ArgoCD platform app).
2. Deploy a `Kafka` CR: 3 brokers, KRaft mode, `gp3-retain` storage, rack awareness across your 2–3 AZs, `replication.factor=3`, `min.insync.replicas=2`.
3. Create `KafkaTopic` CRs declaratively (`orders`, `users`, `orders-dlq`) — note this is GitOps-managed Kafka config, which is the whole point of the operator.
4. Make `order-service` a **producer** and add a new `notification-service` as a **consumer** in a consumer group.
5. Experiment deliberately: kill a broker (does the topic survive?), scale consumers past the partition count (what happens to the extras?), watch a rebalance, watch consumer lag grow and shrink.
6. Implement a **dead letter queue** pattern for messages that fail processing.
7. Add `KafkaUser` CRs with TLS auth + ACLs — Kafka security, not just plaintext.
8. Export Kafka metrics to Prometheus (JMX exporter) and build a Grafana dashboard: consumer lag, under-replicated partitions, broker throughput.

**Verify**
- Produce → consume works; offsets commit
- Kill a broker → no data loss, partitions re-lead
- Consumer lag visible in Grafana; scaling consumers reduces it
- Failed messages land in the DLQ

**Common mistakes:** `replication.factor=1` (any broker loss = data loss); no rack
awareness (all replicas in one AZ); ignoring consumer lag until it's hours deep; too few
partitions to ever scale.

**Cost note:** 💰💰 3 brokers with EBS volumes. Timebox it. **~3 weeks** — Kafka is a
genuinely deep topic and this is the single hardest step in the roadmap.

---

## 13 — `13-kafka-ecosystem`: Schema Registry, Connect, and the rest 💰💰

**Design first**
- **Schema Registry** and why: without it, one producer change breaks every consumer silently. Avro/Protobuf/JSON Schema; backward vs forward vs full compatibility, and what each allows you to change.
- **Kafka Connect**: source/sink connectors as config instead of code. CDC via Debezium (stream your RDS changes into Kafka) — this is a genuinely powerful enterprise pattern.
- **Kafka Streams / ksqlDB**: stream processing, windowing, joins, exactly-once.
- Outbox pattern / transactional messaging: how you avoid "wrote to DB but failed to publish."

**Implement**
1. Deploy Confluent (or Apicurio) **Schema Registry**; switch your producer/consumer to Avro.
2. Deliberately make a breaking schema change and watch the registry reject it. Then make a backward-compatible one and watch it succeed.
3. Deploy **Kafka Connect** via Strimzi's `KafkaConnect` CR + a `KafkaConnector` for an S3 sink (archive all events to S3).
4. Set up **Debezium** CDC from the RDS instance you'll enable in step 23 (or do this step after 23).
5. Deploy **Kafka UI** (provectus) or Redpanda Console for visibility — access via port-forward, never public.
6. Implement the **outbox pattern** in `order-service`.

**Verify** Schema evolution behaves as configured; events land in S3; a DB row change appears
as a Kafka message. **~2 weeks.**

---

## 14 — `14-msk-managed`: The managed alternative 💰💰

**Why:** You should be able to argue self-hosted vs managed with actual numbers, not vibes.

**Implement**
1. Create `modules/msk/` — MSK cluster (or MSK Serverless, which is much cheaper for learning), private subnets, SG, IAM auth, encryption at rest/in transit, CloudWatch logging.
2. Point your existing producer/consumer at MSK by changing only config. (If they were written well, this is a one-line change — a good test of your abstraction.)
3. Compare and **write it up in `docs/msk-vs-strimzi.md`**: cost, upgrade story, scaling, monitoring, IAM vs TLS auth, operational burden, lock-in.
4. Note MSK IAM auth uses a completely different mechanism than Strimzi's TLS/SASL — understand both.

**Cost note:** MSK Serverless, destroy same day. **~1 week.**

---

## 15 — `15-keda-autoscaling`: Event-driven autoscaling

**Design first**
- HPA scales on CPU/memory; but a Kafka consumer should scale on **lag**, an API on **queue depth**, a job on **SQS message count**. KEDA provides those as scalers.
- Scale-to-zero: something HPA can't do. What that means for cold starts.
- KEDA is an HPA *factory* — understand it doesn't replace HPA, it configures it.

**Implement**
1. Install KEDA via Helm.
2. `ScaledObject` for your Kafka consumer using the Kafka lag scaler — min 0, max 10.
3. Produce a burst of 10k messages; watch consumers scale from 0 → N → back to 0.
4. Add a second scaler type (SQS or Prometheus-metric-based) to see the pattern generalizes.
5. Compare KEDA's behavior to plain CPU-based HPA on the same workload.

**Verify** Consumer count tracks lag; scales to zero when the topic is idle. **~1 week.**

---

# PHASE D — API gateway & service mesh

## 16 — `16-kong-gateway`: Kong as your API gateway

**Design first**
- **Ingress controller vs API gateway** — the key distinction. Ingress = "route HTTP into the cluster." API gateway = authn/authz, rate limiting, quotas, transformation, API keys, versioning, developer portal, analytics. Overlapping but different jobs.
- Where the gateway sits: edge (replacing/behind your ALB) vs internal (east-west). North-south vs east-west traffic.
- **Kong DB-less/declarative mode** vs Postgres-backed. DB-less + GitOps is the modern choice — your config becomes YAML in git, which fits everything you've built.
- Kong Ingress Controller CRDs: `KongPlugin`, `KongClusterPlugin`, `KongConsumer`, `KongIngress`, plus Gateway API support.
- **Gateway API** (`HTTPRoute`, `Gateway`, `GatewayClass`) is the successor to Ingress — learn it here, it's the future.
- Alternatives to be aware of: APISIX, Traefik, Ambassador/Emissary, AWS API Gateway. Know when a managed AWS API Gateway beats running Kong.

**Implement**
1. Install Kong Ingress Controller via Helm in DB-less mode, behind an NLB (or as an ALB target).
2. Migrate your three services' routing from the ALB Ingress (step 03) to Kong routes. Keep the ALB in front terminating TLS; Kong does L7 logic.
3. Define routes/services declaratively; commit the config to `gitops/platform/kong/`.
4. Do it a second time with **Gateway API** `HTTPRoute` resources instead of `Ingress`, and compare the two models.
5. Set up API versioning: `/v1/orders` and `/v2/orders` routing to different service versions.
6. Wire Kong's Prometheus metrics into your Grafana.

**Verify** All traffic flows through Kong; `kubectl get httproute` shows your routes; per-route
metrics in Grafana. **~2 weeks.**

---

## 17 — `17-kong-plugins`: What a gateway is actually for

**Design first**
- Which concerns belong at the gateway vs in the app? (Rate limiting, authn, CORS → gateway. Business logic → app.) Getting this boundary right is the real skill.
- Rate limiting strategies: fixed window, sliding window, token bucket; local vs cluster-wide counters (needs Redis — you already have ElastiCache!).
- API authn options: key auth, JWT, OAuth2/OIDC, mTLS. Which for internal vs partner vs public APIs?
- Plugin ordering and scope (global vs service vs route vs consumer).

**Implement**
1. `rate-limiting` plugin backed by your existing ElastiCache Redis (cluster-wide counters). Test with a burst; confirm 429s.
2. `key-auth` + `KongConsumer` resources; give two consumers different rate limit tiers.
3. `jwt` plugin: issue a JWT, validate it at the gateway, pass claims upstream as headers.
4. `cors`, `request-transformer` (inject headers), `response-transformer`.
5. `prometheus` plugin for per-consumer/per-route metrics; dashboard them.
6. `request-termination` + a canary weight setup for a controlled rollout.
7. Chain multiple plugins on one route and reason about ordering.

**Verify** Unauthenticated → 401; over quota → 429; JWT claims reach the upstream service;
per-consumer metrics in Grafana. **~1.5 weeks.**

---

## 18 — `18-service-mesh`: Istio or Linkerd 💰

**Design first**
- What a mesh gives you that a gateway doesn't: **automatic mTLS between all services**, L7 retries/timeouts/circuit breaking without app code, fine-grained traffic splitting, and golden-signal metrics for free.
- Sidecar (Istio/Linkerd classic) vs **ambient/sidecar-less** (Istio ambient mode, Cilium). Sidecars cost ~50-100MB RAM per pod — at scale that's real money.
- **Do you even need a mesh?** With 3 services, honestly no. Learn it because enterprises use it and interviews ask, but understand the complexity cost. Linkerd is far simpler than Istio; start there.
- Istio concepts: `VirtualService`, `DestinationRule`, `Gateway`, `PeerAuthentication`, `AuthorizationPolicy`.
- How mesh + Kong coexist (gateway at the edge, mesh for east-west) — a very common enterprise pattern.

**Implement**
1. Install **Linkerd** first (simpler): CLI, control plane, `linkerd check`, mesh one namespace.
2. Observe: `linkerd viz` gives you golden signals with zero instrumentation. Compare to the work you did in step 07.
3. Enforce mTLS; verify with `linkerd edges` that traffic is encrypted.
4. Add retries + timeouts via `ServiceProfile`; inject failures and watch retries happen.
5. **Then** replace it with **Istio** (in ambient mode if you're feeling brave): repeat mTLS, add `AuthorizationPolicy` for zero-trust service-to-service rules ("only frontend may call order-service").
6. Traffic splitting: 90/10 between two versions of a service.
7. Write up the comparison and your honest opinion on when a mesh is worth it.

**Verify** mTLS everywhere; a policy denying frontend→user-service actually blocks it;
traffic splits by weight. **~2.5 weeks.**

---

## 19 — `19-network-policies`: Zero-trust networking

**Design first**
- By default in K8s, **every pod can talk to every other pod** — including across namespaces. That's the thing to fix.
- `NetworkPolicy` is deny-by-default *once a policy selects a pod* — a subtle and frequently misunderstood rule.
- The AWS VPC CNI doesn't enforce NetworkPolicy by default; you need the policy agent enabled, or **Calico**/**Cilium**.
- Cilium (eBPF) gives L7 policies, better observability (Hubble), and can replace kube-proxy. This is where the industry is heading.
- Egress control: should your pods be able to reach the entire internet? (Yours currently can.) Also: the metadata endpoint (169.254.169.254) should be blocked from pods — that's an IRSA-bypass vector.

**Implement**
1. Enable NetworkPolicy enforcement (VPC CNI's built-in agent, or install Cilium).
2. Write a default-deny-all policy per namespace, then explicitly allow only what's needed: frontend→order-service, order-service→Redis, order-service→Kafka, everything→DNS.
3. Block pod egress to the instance metadata endpoint.
4. Restrict egress to only what's needed (Kafka, RDS, AWS APIs) instead of `0.0.0.0/0`.
5. If you installed Cilium: L7 policy (allow `GET /api/orders` but deny `DELETE`), and explore Hubble's flow visibility.
6. Tighten your **security groups** too — replace the `vpc_cidr`-wide rules in `modules/database` with security-group-to-security-group references (this was flagged in `ISSUES.md` #9 and never fixed!).

**Verify** `kubectl exec` into frontend, try to curl user-service directly → blocked. Try
the metadata endpoint → blocked. DNS still works.

**~1.5 weeks.**

---

# PHASE E — Progressive delivery

## 20 — `20-argo-rollouts`: Canary and blue/green, automated

**Design first**
- Why plain `RollingUpdate` isn't enough: it doesn't check whether the new version is actually *good*, only that pods are Ready.
- Canary (shift % of traffic gradually) vs blue/green (full parallel env, instant cutover). Cost and rollback-speed tradeoffs.
- **Automated analysis** is the key idea: query Prometheus during rollout; if error rate exceeds threshold, abort and roll back automatically. This is where step 07's metrics pay off.
- Metric selection for gates: error rate and latency, not CPU.
- How this integrates with Kong (step 17) or a mesh (step 18) for actual traffic weighting.

**Implement**
1. Install Argo Rollouts + the kubectl plugin.
2. Convert `frontend`'s Deployment to a `Rollout` with a canary strategy: 10% → pause → 25% → 50% → 100%.
3. Write an `AnalysisTemplate` querying your Prometheus for success rate; gate each step on it.
4. Deploy a deliberately broken version; watch it auto-abort and roll back. **This is the moment progressive delivery clicks.**
5. Add traffic routing integration (Kong or mesh) so the % is real traffic weighting, not just pod ratios.
6. Do a blue/green rollout for a second service with `previewService` and manual promotion.
7. Add the Argo Rollouts dashboard; watch a rollout live.

**Verify** Bad deploy auto-reverts without you touching anything. Good deploy promotes
through all steps. **~2 weeks.**

---

## 21 — `21-argo-workflows-events`: Pipelines and event-driven automation

**Design first**
- Argo Workflows (K8s-native DAG pipelines) vs Jenkins. When is a K8s-native runner better? (Ephemeral, scalable, containers as steps, no plugin hell.)
- Argo Events: sources → sensors → triggers. Event-driven ops (a Kafka message triggers a workflow; an S3 upload triggers processing).
- Workflow templates, artifacts (S3), parameters, retries, exit handlers.

**Implement**
1. Install Argo Workflows + Argo Events.
2. Build a workflow that does build → test → scan → push for one service (mirror your Jenkins pipeline, then compare them honestly).
3. Use S3 as the artifact repository (Terraform bucket + IRSA).
4. Argo Events: a Kafka message on a topic triggers a workflow. Also: an S3 upload triggers a processing workflow.
5. Add a `CronWorkflow` for a nightly task (backup verification, report generation).
6. Write up when you'd choose Jenkins vs Argo Workflows vs GitHub Actions.

**~1.5 weeks.**

---

## 22 — `22-feature-flags`: Decouple deploy from release

**Design first**
- Deploying code ≠ releasing a feature. Flags let you ship dark, enable per-user, and kill instantly without a deploy.
- Flag types: release, ops (kill switches), experiment (A/B), permission.
- **Flag debt** is real — every flag is a branch in your code. Have a removal policy.
- Build vs buy: Unleash/Flagsmith (self-host) vs LaunchDarkly (SaaS).

**Implement**
1. Deploy **Unleash** (or Flagsmith) with a Postgres backend on your cluster.
2. Add the SDK to `frontend`; wrap a new feature in a flag.
3. Percentage rollout, then user-attribute targeting.
4. Add an ops kill-switch flag around the Kafka producer; flip it and watch behavior change with no deploy.
5. Combine with Argo Rollouts: deploy dark via canary, then release via flag. Understand why this combination is powerful.

**~1 week.**

---

# PHASE F — Data layer

## 23 — `23-rds-production`: Actually turn on the database, properly 💰

**Why:** `enable_rds = false` everywhere. You have the module but have never run it. Also
your `modules/database` security groups are still VPC-CIDR-wide (`ISSUES.md` #9).

**Design first**
- Multi-AZ (sync standby, automatic failover, ~60s) vs read replicas (async, for read scaling) — different problems, often confused.
- Parameter groups & option groups; what's worth tuning (`max_connections`, `shared_buffers`, `work_mem`).
- **Connection pooling**: K8s + autoscaling means pod count × pool size can exhaust Postgres connections fast. RDS Proxy or PgBouncer. This bites people constantly.
- Credential management: you already use `manage_master_user_password` (Secrets Manager managed) — now add **rotation** and understand IAM database auth as an alternative.
- Encryption at rest (KMS — customer-managed vs AWS-managed keys), in transit (`sslmode=require`), and why `rds.force_ssl` matters.
- Backup/retention/PITR, `deletion_protection`, final snapshots (your module already has good defaults — understand *why*).
- Performance Insights & Enhanced Monitoring.
- Aurora vs standard RDS: storage architecture, failover speed, cost.

**Implement**
1. Set `enable_rds = true` for dev; apply. Read every argument in `modules/database/main.tf` and make sure you can explain it.
2. Enable Multi-AZ; **force a failover** from the console and measure the downtime your app sees.
3. Add a read replica; route reads to it from `order-service`.
4. Add a custom parameter group with `rds.force_ssl = 1`; fix your app to use TLS.
5. Fix the security groups: replace `cidr_blocks = [var.vpc_cidr]` with `source_security_group_id` referencing the EKS node SG.
6. Add **RDS Proxy** (or deploy PgBouncer); compare connection behavior under HPA scale-up.
7. Enable Performance Insights; find a slow query you caused deliberately.
8. Set up Secrets Manager **rotation** for the DB credential; confirm the app picks up the new password (this is where ESO's `refreshInterval` matters).
9. Wire RDS CloudWatch metrics into Grafana; alert on connections, CPU, storage, replica lag.

**Verify** Failover < 90s with app recovery; replica lag visible; app works with SSL enforced;
rotation doesn't break the app.

**Cost note:** `db.t4g.micro`, Multi-AZ doubles it. Destroy after. **~2 weeks.**

---

## 24 — `24-db-migrations`: Schema changes without downtime

**Design first**
- Migrations must be automated, versioned, and repeatable. Never hand-run SQL in prod.
- Where do they run? Init container / K8s `Job` / ArgoCD PreSync hook / CI step — each has real tradeoffs around ordering and rollback.
- **Expand-contract (parallel change)**: the only safe way to make a breaking schema change with zero downtime. Add column → dual-write → backfill → switch reads → stop writing old → drop. You must know this pattern.
- Backward compatibility between app version N and schema version N+1 — because during a rollout both exist simultaneously.
- Locking danger: `ALTER TABLE` on a big table can lock writes and take your site down.

**Implement**
1. Add **Flyway** (or Liquibase) migrations to one service; version-control the SQL.
2. Run migrations as an ArgoCD **PreSync hook** Job; understand hook ordering and failure behavior.
3. Do a real expand-contract rename across multiple deploys, verifying zero downtime at each stage with a `curl` loop.
4. Deliberately write a migration that fails halfway; observe what happens and how you recover.
5. Add a migration-lint step to CI (block dangerous operations).
6. Practice a rollback: app rollback with schema forward-compatible.

**~1.5 weeks.**

---

## 25 — `25-backup-dr`: Backups you've actually tested

**Design first**
- **RTO** (how fast to recover) vs **RPO** (how much data you can lose). Pick numbers for each of your components — this framing drives every DR decision.
- An untested backup is not a backup. Restore drills are the deliverable, not the backup job.
- What needs backing up: RDS (automated + snapshots), etcd/cluster state (**Velero**), PVs (volume snapshots), S3 (versioning + replication), Secrets Manager, and **your Terraform state** (versioning on that bucket!).
- Backup immutability / ransomware protection: separate account, object lock, MFA delete.

**Implement**
1. Enable S3 versioning + a lifecycle policy on your Terraform state bucket (check whether it's on — if not, that's a finding).
2. Configure **AWS Backup** via Terraform: backup plan, vault, selection by tag; cover RDS + EBS + EFS.
3. Install **Velero** with an S3 backend + IRSA; back up a namespace including PVs.
4. **Destroy a namespace and restore it from Velero.** Time it. Write down the actual RTO.
5. RDS point-in-time restore: restore to 5 minutes ago into a new instance. Time it.
6. Write `docs/runbooks/disaster-recovery.md` with real measured numbers, not aspirational ones.
7. Schedule a monthly restore drill (CronWorkflow from step 21 can remind you).

**Verify** You have restored, from scratch, at least once, and know your real RTO/RPO.

**~1.5 weeks.**

---

## 26 — `26-dynamodb-caching`: NoSQL and cache patterns

**Design first**
- When DynamoDB beats RDS: key-value access at scale, unpredictable spikes, serverless. When it doesn't: complex queries, joins, transactions across many items.
- Single-table design, partition/sort keys, GSI/LSI, hot partitions. On-demand vs provisioned capacity.
- Cache patterns with your existing Redis: cache-aside, write-through, write-behind. TTL strategy.
- **Cache invalidation and the thundering herd**; cache stampede protection.
- DynamoDB Streams → Kafka/Lambda for event-driven flows.

**Implement**
1. `modules/dynamodb/` — a table with a GSI, on-demand billing, PITR, encryption.
2. IRSA role for a service to access only that table.
3. Implement cache-aside against your ElastiCache Redis; measure the latency difference with and without cache (use your tracing from step 10).
4. Cause a cache stampede deliberately, then fix it (locking or probabilistic early expiry).
5. Enable DynamoDB Streams → Kafka via Kafka Connect (ties back to step 13).
6. Add Redis + DynamoDB metrics to Grafana; alert on cache hit rate dropping.

**~1.5 weeks.**

---

# PHASE G — Security & compliance

## 27 — `27-pod-security-policy`: Policy as code

**Design first**
- PodSecurityPolicy is dead; **Pod Security Standards** (privileged/baseline/restricted) via Pod Security Admission replaced it.
- PSA is coarse (3 levels, namespace-scoped). For real rules you need an admission controller: **Kyverno** (YAML, K8s-native, easier) vs **OPA Gatekeeper** (Rego, more powerful, steeper).
- Validating vs mutating vs generating policies. Audit mode before enforce mode — always.
- Policy examples worth writing: no `:latest` tags, required labels, no privileged containers, resource limits mandatory, only approved registries, no hostPath.

**Implement**
1. Enable Pod Security Admission at `restricted` on your app namespaces. Fix whatever breaks (step 02's securityContext work should mostly cover you).
2. Install **Kyverno**; write validating policies in *audit* mode first, review violations, then flip to *enforce*:
   - disallow `:latest`, require `app.kubernetes.io/*` labels, require resource limits, only allow images from your ECR, disallow privileged/hostNetwork/hostPath
3. Write a **mutating** policy (auto-add default securityContext) and a **generating** policy (auto-create a default NetworkPolicy in every new namespace).
4. Try one equivalent policy in **OPA Gatekeeper** with Rego to feel the difference.
5. Add policy reports to Grafana; alert on violations.
6. Add `kyverno-cli` policy tests to your CI so policies are tested like code.

**Verify** A deploy with `:latest` is rejected. A new namespace automatically gets a
NetworkPolicy. **~1.5 weeks.**

---

## 28 — `28-supply-chain`: Secure the path from code to running container

**Design first**
- The supply chain attack surface: base images, dependencies, build system, registry, admission. (Look up SolarWinds and `event-stream` for why this matters.)
- **SBOM** (Software Bill of Materials) — CycloneDX/SPDX. Why regulators increasingly require it.
- Vulnerability scanning at three points: dependencies (CI), image (registry), runtime (cluster). Your ECR already has `scan_on_push` — build on that.
- **Image signing** (Cosign/Sigstore) + admission verification: only run images your pipeline signed. Keyless signing with OIDC.
- Provenance/attestations, SLSA levels.
- Pinning by **digest** not tag (a tag is mutable; a digest isn't).

**Implement**
1. Add **Trivy** to your Jenkins pipeline: scan filesystem, dependencies, and the built image; fail the build on HIGH/CRITICAL.
2. Generate an SBOM with **Syft**; attach it to the image and archive it.
3. Sign images with **Cosign** (keyless, OIDC) in the pipeline.
4. Install a policy to **verify signatures at admission** (Kyverno `verifyImages`). Try to deploy an unsigned image → rejected.
5. Install **Trivy Operator** in-cluster for continuous scanning of running workloads; dashboard the findings.
6. Switch your manifests to digest pinning; automate digest bumps.
7. Add **Dependabot/Renovate** to both repos for dependency and Helm chart updates.
8. Scan your Terraform with `tfsec` + `checkov` (you already run Checkov in Jenkins — now make it actually fail the build and fix what it finds).

**Verify** Unsigned image → blocked. Vulnerable dependency → build fails. SBOM exists for
every image. **~2 weeks.**

---

## 29 — `29-runtime-security`: Detect what gets past you

**Design first**
- Prevention (steps 27–28) always eventually fails; you need detection. Defense in depth.
- **Falco** (eBPF syscall monitoring): detect shell-in-container, unexpected network connections, writes to sensitive paths, privilege escalation.
- Signal vs noise: default rules are noisy. Tuning is the actual work.
- K8s **audit logging** — who did what to the API server. Enable it on EKS and ship it to your ELK.
- Incident response: what do you actually *do* when Falco fires?

**Implement**
1. Enable EKS control plane audit logs → CloudWatch → ship to Elasticsearch (step 09). Query "who deleted that deployment?"
2. Install **Falco** with the eBPF driver; ship alerts to Falcosidekick → Slack.
3. Trigger detections deliberately: `kubectl exec` a shell, write to `/etc/passwd`, curl the metadata endpoint, run a crypto-miner-shaped process.
4. Tune out the false positives from your own platform components. Document why each exception is safe.
5. Write `docs/runbooks/security-incident.md`: contain (NetworkPolicy isolation), collect evidence, evict, rotate credentials, post-mortem.
6. Run a tabletop exercise: "a pod is mining crypto — go."

**~1.5 weeks.**

---

## 30 — `30-vault`: Dynamic secrets 💰

**Design first**
- You already have Secrets Manager + ESO. What does Vault add? **Dynamic secrets** (short-lived, generated per-request DB credentials), PKI (issue certs on demand), transit encryption (encryption-as-a-service), and cloud-agnosticism.
- Static vs dynamic secrets — a 1-hour DB credential is a fundamentally different security posture than a rotated-quarterly one.
- Vault auth methods: Kubernetes auth (SA token → Vault role), AWS IAM auth.
- Injection: Vault Agent sidecar vs **Vault Secrets Operator** vs CSI provider.
- Seal/unseal, auto-unseal with KMS, and why Vault HA needs Raft + persistent storage (step 05 again).
- **Be honest:** for a small AWS-only shop, Secrets Manager + ESO is often the right answer. Know when Vault's complexity is justified.

**Implement**
1. Deploy Vault in HA mode (Raft, 3 replicas, `gp3-retain`) with KMS auto-unseal.
2. Enable Kubernetes auth; map a ServiceAccount to a Vault role/policy.
3. **Dynamic database secrets**: configure the DB secrets engine against your RDS; have a service get a 1-hour credential at startup. Watch it expire and renew.
4. Vault PKI engine: issue an internal cert; compare with cert-manager from step 03.
5. Transit engine: encrypt a field in your app without the app ever holding a key.
6. Write up Vault vs Secrets Manager+ESO — cost, complexity, capability, when each wins.

**Cost note:** 3 Vault pods + KMS. Destroy after. **~2 weeks.**

---

## 31 — `31-aws-security-services`: The account-level layer 💰

**Design first**
- Everything so far was cluster-level. Enterprises also need account/org-level detection and governance.
- **GuardDuty** (threat detection from logs, incl. EKS runtime monitoring), **Security Hub** (findings aggregation + standards), **AWS Config** (resource compliance rules + drift), **CloudTrail** (API audit — the single most important log in AWS), **IAM Access Analyzer** (find over-permissive/external access).
- Preventive vs detective vs responsive controls.
- **SCPs** (Service Control Policies) as org-level guardrails — preventive, can't be bypassed even by admins.

**Implement**
1. Enable **CloudTrail** via Terraform: org trail, S3 + CloudWatch, log file validation, KMS encryption. Query it for your own Terraform actions.
2. Enable **GuardDuty** including EKS protection; trigger a finding (the metadata-endpoint curl from step 29 should do it).
3. Enable **Security Hub** with the CIS AWS Foundations + EKS standards. Look at your score. **Fix the top 10 findings** — this is the real learning.
4. **AWS Config** rules: encrypted volumes, no public S3, required tags, SG restrictions. Add an auto-remediation for one.
5. **IAM Access Analyzer**: run it against the policies you wrote in this session. Note anything it flags (especially your Jenkins policy).
6. Ship all findings to Slack via EventBridge → SNS.
7. Cost/benefit writeup: GuardDuty is priced by volume — know what you'd enable at what company size.

**Cost note:** GuardDuty + Config have ongoing costs. Enable, learn, screenshot your Security
Hub score improvement, disable. **~1.5 weeks.**

---

## 32 — `32-compliance-benchmarks`: Prove it

**Design first**
- Compliance ≠ security, but it forces documentation and repeatability. SOC2 / ISO 27001 / PCI-DSS / HIPAA at a conceptual level: what auditors actually ask for.
- Evidence collection and continuous compliance vs annual scramble.
- CIS Benchmarks for Kubernetes and EKS.

**Implement**
1. Run **kube-bench** against your cluster; work through the failures you can fix on EKS (some are AWS-managed and not yours).
2. Run **kube-hunter** (or Trivy's k8s misconfiguration scan) and triage.
3. Run **Prowler** against your AWS account for a multi-framework compliance report.
4. Create a `docs/compliance/` set: data flow diagram, asset inventory, access review process, change management (your PR + approval flow *is* this), incident response plan, backup/DR evidence (step 25).
5. Automate evidence: a CronWorkflow that runs the scanners weekly and archives reports to S3.
6. Map 10 specific SOC2 controls to the concrete technical control in your repos that satisfies each.

**~1.5 weeks.**

---

# PHASE H — CI/CD maturity & platform engineering

## 33 — `33-github-actions-oidc`: Modern CI without static credentials

**Design first**
- Your Jenkins uses an instance profile (good). But GitHub Actions with **OIDC federation** to AWS = zero long-lived credentials anywhere. Understand the trust-policy mechanics (`token.actions.githubusercontent.com`, `sub` claim conditions) — it's the same OIDC concept as IRSA from step 07's prerequisites.
- Jenkins vs GitHub Actions vs GitLab CI — genuine tradeoffs (self-hosted control vs managed convenience; plugin ecosystem vs YAML simplicity).
- Reusable workflows, composite actions, matrix builds, caching, concurrency groups, environments + required reviewers.
- Runner security: why `pull_request_target` is dangerous, and secret scoping.

**Implement**
1. Terraform an IAM OIDC provider for GitHub + a role with a trust policy locked to *your* repo and branch (`repo:kumarisback/terraform:ref:refs/heads/main`).
2. Build a GHA workflow for a service: lint → test → Trivy scan → build → Cosign sign → push to ECR → bump the tag in the `gitops` repo (closing the GitOps loop automatically).
3. Make it a **reusable workflow** callable by all three services.
4. Add matrix builds, dependency caching, and concurrency cancellation.
5. Use GitHub **Environments** with required reviewers for the prod path.
6. Compare, in writing, against your Jenkins pipeline: speed, maintainability, cost, security.

**Verify** A push to a service repo results in a new image in ECR and an auto-updated tag in
`gitops`, with no AWS keys stored anywhere. **~1.5 weeks.**

---

## 34 — `34-terraform-cicd`: Treat infrastructure like software

**Why:** Your Terraform has no automated tests, no plan-on-PR, no drift detection, and no
linting beyond `fmt`. This is the biggest maturity gap in the `tf` repo.

**Design first**
- Plan-on-PR as the review artifact: reviewers should see the plan, not just the HCL diff.
- **Atlantis** vs Terraform Cloud vs GHA-based plan/apply. Who holds the apply credentials?
- **Drift detection**: someone clicked in the console; how do you find out? Scheduled `plan` with a diff alert.
- Testing pyramid for IaC: `validate`/`fmt` → `tflint`/`tfsec`/`checkov` → `terraform test` (native, 1.6+) → **Terratest** (real resources, slow, expensive) → policy tests (OPA/Sentinel).
- State management at scale: state splitting (you already do 2 layers — why?), blast radius, `moved` blocks, `import` blocks, refactoring safely.

**Implement**
1. Add `tflint` (+ the AWS ruleset) and `tfsec` to the Jenkins pipeline; make Checkov actually *fail* the build (right now it just runs). Fix the findings.
2. Write native `terraform test` files for `modules/networking` and `modules/eks` — assert subnet counts, CIDR math, tag propagation.
3. Write one **Terratest** test that actually applies `modules/networking` into a throwaway VPC, asserts, and destroys. Feel how slow and expensive real integration testing is.
4. Set up plan-on-PR: a GHA workflow posting `terraform plan` output as a PR comment for both layers.
5. Add scheduled **drift detection** (nightly plan; alert if non-empty). Then create drift manually in the console and watch it get caught.
6. Add OPA/Conftest policies over the plan JSON: no public S3, no `0.0.0.0/0` SGs, mandatory tags.
7. Practice refactoring safely: rename a resource using a `moved` block; import an existing resource with an `import` block.
8. Add `infracost` to PRs to see cost deltas before merge.

**Verify** A PR shows plan + cost + policy results. Console drift is detected within 24h.
Tests catch a deliberately broken module. **~2.5 weeks.**

---

## 35 — `35-sonarqube-gates`: Code quality gates

**Design first**
- Coverage is necessary but not sufficient — also: duplication, complexity, code smells, security hotspots.
- **Quality gate on new code** (the "clean as you code" model) vs whole-codebase — why the former is the only realistic approach on legacy code.
- Where the gate blocks: PR check vs post-merge.

**Implement**
1. Deploy SonarQube (on the cluster with a Postgres backend, or use SonarCloud).
2. Add scanning + coverage upload to your CI for one service.
3. Configure a quality gate: coverage ≥80% on new code, zero new blockers, no new security hotspots.
4. Make the gate **block PR merge** via a required status check.
5. Fix a real finding it reports (not a suppression — an actual fix).
6. Add the same for Terraform (Sonar has HCL support) and IaC-specific rules.

**~1 week.**

---

## 36 — `36-artifact-management`: Versioning and provenance

**Design first**
- Semantic versioning; **conventional commits** → automated changelogs and version bumps.
- Immutable artifacts: build once, promote the *same* artifact through dev→staging→prod. Never rebuild per environment (your `newTag: latest` in dev currently violates this in spirit).
- Registries: ECR (you have it) vs Nexus/Artifactory (multi-format: Docker, Helm, npm, Maven). Retention/GC policies.
- Promotion strategy: tag-based vs digest-based; how GitOps repos model environment promotion.

**Implement**
1. Add `semantic-release` (or `release-please`) to a service: conventional commits → auto version, changelog, git tag.
2. Enforce conventional commits with a commit hook + CI check.
3. Set `image_tag_mutability = "IMMUTABLE"` on your ECR repos; understand what breaks and why that's good.
4. Implement digest-based promotion: the same digest flows dev → staging → prod via the gitops repo.
5. Publish your Helm chart (step 06) versioned to ECR OCI on release.
6. Tune ECR lifecycle policies properly (your current one only expires untagged images — add a tagged-image rule, which was flagged in `ISSUES.md` #11).
7. Optional: run Nexus and host a private npm/Maven proxy to see the multi-format use case.

**~1.5 weeks.**

---

## 37 — `37-multi-account-terragrunt`: Enterprise-scale structure 💰

**Design first**
- **Why multiple AWS accounts**: blast radius, billing separation, hard security boundaries, quota isolation. The standard layout: management / security / logging / shared-services / dev / staging / prod.
- AWS **Organizations**, Control Tower, SCPs, cross-account role assumption. Your `jenkins_terraform_deploy_role_arns` variable exists for exactly this and is unused — now use it.
- DRY multi-env: Terragrunt vs workspaces vs your current copy-paste tfvars. Honest tradeoffs — Terragrunt adds a tool; workspaces have real state footguns.
- Centralized logging and security tooling across accounts.

**Implement**
1. Create a second AWS account under Organizations (a sandbox — free to create).
2. Create a cross-account deploy role in it; have Jenkins **assume** it (finally wiring up `terraform_deploy_role_arns` and dropping direct permissions).
3. Refactor your env config with **Terragrunt**: eliminate the duplicated tfvars/backend files, `include` common config, `dependency` blocks between layers (this replaces your manual `terraform_remote_state` reads).
4. Compare against a Terraform-workspaces version of the same thing; write up which you'd choose and why.
5. Apply an SCP that blocks a region or requires encryption; verify even an admin can't bypass it.
6. Centralize CloudTrail + Config into a logging account.

**Cost note:** two accounts = double the infra if you run both. Run one at a time.
**~2 weeks.**

---

## 38 — `38-backstage-crossplane`: Platform engineering 💰

**Design first**
- **Platform engineering** vs DevOps: build an internal platform so product teams self-serve, instead of filing tickets to you. This is the current industry direction and where senior roles are heading.
- Golden paths / paved roads: opinionated, supported defaults.
- **Backstage**: software catalog, scaffolder (templates for new services), TechDocs, plugins.
- **Crossplane**: provision AWS infra via K8s CRDs; compositions as your platform API. Crossplane vs Terraform — where each fits, and whether you'd really replace TF.
- Platform-as-product thinking: your users are developers; measure their experience.

**Implement**
1. Deploy **Backstage** (Postgres backend, GitHub auth).
2. Register your services in the software catalog via `catalog-info.yaml`.
3. Build a **scaffolder template**: "new microservice" → creates a repo from a skeleton, adds the Helm chart from step 06, adds the ArgoCD Application, adds the ECR repo, opens the PRs. **This is the payoff of everything before it.**
4. Add plugins: ArgoCD (deploy status), Kubernetes (live pod status), Grafana, SonarQube.
5. Install **Crossplane** + the AWS provider; write a `Composition` + `CompositeResourceDefinition` for "an S3 bucket with encryption and versioning."
6. Have a developer-facing `Claim` provision real AWS infra through K8s. Compare with the Terraform equivalent and write up the tradeoff honestly.

**~2.5 weeks.** Genuinely hard, genuinely differentiating.

---

# PHASE I — Resilience & cost

## 39 — `39-chaos-engineering`: Break it on purpose

**Design first**
- Hypothesis-driven experiments: "if one Kafka broker dies, consumer lag stays under X and no messages are lost." Then test it.
- Steady-state definition, blast radius control, abort conditions. Never run chaos without observability (Phase B) in place.
- Start in dev. GameDays as a team practice.
- Failure modes worth testing: pod kill, node kill, AZ loss, network latency/partition, DNS failure, disk fill, CPU/memory pressure, dependency (RDS/Redis/Kafka) unavailability.

**Implement**
1. Install **Chaos Mesh** (or LitmusChaos).
2. Write down 6 hypotheses with measurable steady states before running anything.
3. Run experiments in ascending blast radius: pod-kill → container-kill → network-delay → network-partition → node-drain → simulated AZ loss.
4. Inject 300ms latency between frontend and order-service; watch your traces (step 10) and SLO burn (step 08).
5. Kill a Kafka broker under load; verify your step-12 assumptions actually hold.
6. Fill a PVC to 100%; see what breaks and whether you get alerted.
7. **Fix every weakness you find**, then re-run to prove the fix.
8. Write `docs/gameday-<date>.md` for each: hypothesis, method, result, action items.

**Verify** At least 3 real weaknesses found and fixed. **~1.5 weeks.**

---

## 40 — `40-load-testing`: Know your limits before your users do

**Design first**
- Test types and what each answers: smoke, load (expected), stress (find the breaking point), spike, soak (memory leaks over hours), breakpoint.
- Test *in* CI (regression) vs *against* a prod-like env (capacity planning).
- Metrics that matter: p95/p99 latency, error rate, throughput — **not** averages.
- Capacity planning: from load test → headroom → autoscaling config → cost model.
- Little's Law, and why queueing theory explains latency cliffs.

**Implement**
1. Write **k6** scripts: smoke, ramping load, spike, and a 1-hour soak, with thresholds as pass/fail.
2. Run them from inside the cluster as a K8s Job; export metrics to Prometheus.
3. Find your actual breaking point. Where does it break — pods, nodes, DB connections, Kafka?
4. Watch your autoscaling (step 04) and KEDA (step 15) respond in real time.
5. Fix the top bottleneck (very likely DB connection pooling from step 23), re-test, quantify the improvement.
6. Run the soak test; check for memory leaks in the Grafana graphs.
7. Add a k6 smoke test as a post-deploy gate in your pipeline.
8. Write `docs/capacity-plan.md`: requests/sec per pod, cost per 1000 requests, headroom target.

**~1.5 weeks.**

---

## 41 — `41-cost-optimization`: FinOps

**Design first**
- Cost is a reliability feature — running out of budget is an outage. FinOps: inform → optimize → operate.
- Kubernetes cost allocation is genuinely hard (shared nodes) — **OpenCost/Kubecost** solves attribution by namespace/label/team.
- The levers, roughly in order of impact: rightsizing → spot → autoscaling/scale-to-zero → Savings Plans/RIs → storage tiering → data transfer → idle resource cleanup.
- Data transfer costs (cross-AZ! your single-NAT design has cross-AZ charges; NAT itself charges per GB).
- Tagging strategy and showback/chargeback.

**Implement**
1. Enable **Cost Explorer** + AWS **Budgets** with alerts via Terraform. Enable the Cost and Usage Report to S3.
2. Enforce a tagging policy (Kyverno for K8s, Config rules + `default_tags` for AWS). You already have `default_tags` — add `Team`/`CostCenter`.
3. Install **OpenCost** (or Kubecost); dashboard cost per namespace/service in Grafana.
4. Rightsize: compare your step-02 requests/limits against actual usage from Prometheus + VPA recommendations. Fix over-provisioning.
5. Move dev node groups to **Spot** (`node_capacity_type = "SPOT"`); measure the savings.
6. Scale dev to zero overnight (a CronWorkflow scaling node groups down at 8pm, up at 8am). Measure.
7. Add S3 lifecycle policies for your logs/artifacts (Standard → IA → Glacier → delete).
8. Find and kill waste: unattached EBS volumes, unused EIPs, old snapshots, idle load balancers, orphaned ENIs. (Write a script — you'll find some, guaranteed.)
9. Model Savings Plans for a hypothetical steady prod workload.
10. Write `docs/cost-report.md`: before/after, cost per environment, per service, per 1000 requests.

**Verify** A measurable, documented reduction in your own AWS bill. **~1.5 weeks.**

---

## 42 — `42-multi-region-dr`: The big one 💰💰💰

**Design first**
- DR strategies by cost/RTO: backup-restore (hours, cheap) → pilot light → warm standby → active-active (seconds, expensive). Pick per-workload; nobody makes everything active-active.
- Stateless is easy; **state is the whole problem**: RDS cross-region read replicas / Aurora Global, DynamoDB Global Tables, S3 CRR, Kafka MirrorMaker2.
- Global routing: Route53 health checks + failover/latency routing, or Global Accelerator.
- Data sovereignty, replication lag, split-brain, and the reality of CAP.
- **Regional failover must be practiced** or it won't work when needed.

**Implement**
1. Extend your Terraform to a second region with a provider alias (this will expose every hardcoded region in your code — good).
2. Deploy a **pilot light** in region 2: VPC + a minimal EKS + replicated data, no traffic.
3. RDS cross-region read replica; S3 cross-region replication; ECR cross-region replication.
4. Route53 health check + failover routing between regions.
5. **Run an actual failover drill**: break region 1, promote region 2, measure RTO/RPO. Then fail back.
6. Kafka MirrorMaker2 between regions (if budget allows — this is the expensive part).
7. Write `docs/runbooks/regional-failover.md` with your measured numbers.
8. Cost the whole thing out and write down what you'd actually recommend to a business at each of three budget levels.

**Cost note:** 💰💰💰 The most expensive step by far. Consider designing it fully, applying
it for a single afternoon, doing the drill, and destroying it the same day. Or design-only
with a `terraform plan` + `infracost` estimate if budget doesn't allow — the design
thinking is 80% of the value here. **~2 weeks.**

---

# PHASE J — Capstone

## 43 — `43-capstone`: Bring it together and prove you can run it

Not new tech — **integration, documentation, and operational proof**. This is what turns
43 branches into a coherent skill set (and a genuinely strong portfolio/interview story).

**Deliverables**

1. **Reference architecture doc** — update `ARCHITECTURE.md` to cover everything you added. Diagrams for: network topology, request path (user → DNS → ALB → Kong → mesh → pod → DB/Kafka), CI/CD flow, observability pipeline, security controls, DR topology.
2. **Runbook library** — `docs/runbooks/` for: high error rate, high latency, pod crashloop, node not ready, DB failover, Kafka lag, cert expiry, disk full, security incident, regional failover. Each: symptoms → diagnosis → remediation → escalation.
3. **On-call docs** — alert → runbook mapping, escalation policy, severity definitions.
4. **Decision records** — `docs/adr/` capturing every "X vs Y" you compared: Strimzi vs MSK, Kong vs ALB Ingress, Istio vs Linkerd, ELK vs Loki, Vault vs Secrets Manager, Terragrunt vs workspaces, Crossplane vs Terraform. Context, options, decision, consequences. **ADRs are what senior engineers are actually assessed on.**
5. **A full end-to-end demo you can run in under an hour**: code commit → CI (test/scan/sign) → ECR → GitOps commit → ArgoCD sync → canary rollout with automated analysis → observability showing the rollout → deliberate failure → auto-rollback → alert → runbook.
6. **A rebuild-from-zero test**: destroy *everything*, then rebuild the whole platform from an empty AWS account using only your docs. Time it. Fix every gap you hit. This is the single best test of whether your IaC and docs are real.
7. **An honest "what I'd do differently" writeup.**

**~3 weeks.** Worth every hour.

---

# Appendix

## A. Things deliberately not in the numbered path

Worth knowing about; pick up opportunistically:

- **Other clouds** — GCP/GKE, Azure/AKS. Concepts transfer; take one weekend to deploy a service on GKE to see what's AWS-specific vs universal.
- **Serverless** — Lambda, API Gateway, Step Functions, EventBridge, Fargate. A different compute model; know when it beats K8s (spiky/low-volume/glue work).
- **Nomad / ECS** — orchestrators that aren't K8s. ECS is very common at AWS-only shops and much simpler.
- **eBPF deep dive** — Cilium, Pixie, Parca. Increasingly where infrastructure innovation happens.
- **WASM** — early but watch it.
- **AI/ML ops** — Kubeflow, model serving, GPU scheduling. Big growth area.
- **Databases deeper** — query planning, indexing strategy, replication internals. Enormous leverage; most DevOps engineers are weak here.
- **Programming** — get properly good at Go or Python. Writing a K8s operator (kubebuilder) or a real CLI tool is what separates senior from mid.

## B. Anti-patterns to actively avoid while learning

- **Tutorial hell** — copying commands without understanding. The *Design* sections exist to prevent this. If you can't explain *why*, you haven't finished the step.
- **Tool collecting** — knowing 40 tools shallowly is worth less than 10 deeply. Depth on fundamentals (networking, Linux, K8s core, IAM) beats breadth on tools.
- **Skipping the boring parts** — RBAC, probes, backups, and docs are what production actually is. Kafka is more fun; probes will save you more often.
- **Never destroying** — if you can't rebuild it from code, you don't have infrastructure-as-code, you have expensive pets.
- **No verification** — "it applied without error" ≠ "it works." Every step has a *Verify* section for a reason.
- **Learning in isolation** — write up what you build. Blog it, or just keep good `NOTES.md` files. Teaching is how you find the holes in your understanding.

## C. Rough interview-readiness milestones

| After step | You can credibly claim |
|---|---|
| 06 | Junior DevOps / Cloud Engineer |
| 11 | Mid-level DevOps — you can *operate* things, not just deploy them |
| 19 | Solid mid/senior — platform-capable |
| 32 | Senior DevOps / SRE — security and compliance literate |
| 38 | Platform Engineer — you can build platforms, not just use them |
| 43 | Staff/Lead-capable — you have architecture judgment and can defend it |

## D. Weekly rhythm that works

- **Mon–Thu (1.5h/day):** read the design section, then implement in small commits
- **Fri (2h):** verify + break it on purpose + write `NOTES.md`
- **Sat (2h):** the hard part of the step, uninterrupted
- **Sun:** off. Also: **check your AWS bill** and destroy anything still running.

Every 4 weeks: revisit an earlier branch and improve it with what you've since learned.
Spaced repetition works.

---

*Start with step 01. Set the AWS budget alert first.*
