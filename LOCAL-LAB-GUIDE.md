# DevOps Learning Roadmap — Local KinD Lab Execution Guide

> **Purpose**: A complete operational guide to practicing 75%+ of the `LEARNING-ROADMAP.md` locally using KinD (Kubernetes in Docker) for **$0**, with fast feedback loops, zero risk of AWS surprise billing, and rapid teardown/rebuild.

---

## 1. Executive Summary & Strategy

The learning roadmap spans 43 real-world engineering steps. Running all of them directly on AWS EKS incurs compute costs, ALB costs, NAT Gateway charges, and slow iteration times (15+ min provisioning/teardown).

By using a local **KinD (Kubernetes in Docker)** multi-node cluster (`dev-lab`), you can master:
- **Core Kubernetes Architecture**: RBAC, Probes, Resource limits, PDBs, StatefulSets, PVCs, Helm authoring.
- **Full Observability Stack**: Prometheus, Grafana, Alertmanager, Promtail, Loki, OpenTelemetry, Tempo.
- **Event Streaming**: Strimzi Kafka, Kafka Topics/Users, Schema Registry, Kafka Connect, KEDA.
- **Traffic & Mesh**: Kong Ingress, Gateway API, rate limiting, Linkerd/Istio mTLS, NetworkPolicies.
- **Progressive Delivery**: Argo Rollouts (Canaries, Blue/Green, automated analysis), Argo Workflows.
- **Security & Reliability**: Kyverno policies, Falco eBPF, Vault, Chaos Mesh, k6 load testing.

### The 3-Tier Execution Model

```
┌────────────────────────────────────────────────────────────────────────┐
│  Tier 1: 100% Local in KinD ($0, complete fidelity)                   │
│  Steps: 01, 02, 05, 06, 07, 08, 09, 10, 11, 12, 13, 15, 16, 17, 18,   │
│         19, 20, 21, 22, 24, 26, 27, 28, 29, 30, 32, 35, 39, 40, 41   │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 2: KinD with Lightweight Local Mocks ($0)                        │
│  • Ingress/TLS: Ingress-NGINX or Kong + cert-manager local CA (Step 03)│
│  • Storage / S3: MinIO or LocalStack (Step 10, 21)                    │
│  • Databases: Bitnami Postgres / Redis in KinD (Step 23, 26)           │
├────────────────────────────────────────────────────────────────────────┤
│  Tier 3: AWS Cloud-Only (Timeboxed 1–2 hr sessions)                   │
│  • Step 03: AWS ALB Controller + ACM + Route53 public validation       │
│  • Step 04: Karpenter EC2 spot provisioning                            │
│  • Step 14: AWS MSK Serverless                                        │
│  • Step 23: AWS RDS Multi-AZ failover drill                            │
│  • Step 25: AWS Backup                                                 │
│  • Step 31: GuardDuty, Security Hub, AWS Config, CloudTrail           │
│  • Step 33: GitHub Actions OIDC to AWS IAM                             │
│  • Step 37 & 42: Multi-account Terragrunt & Multi-region DR            │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. KinD Cluster Configuration & Adjustments

### 2.1 Current Cluster vs Ingress-Ready Cluster

Your current cluster was created with:
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
```

#### How to access services in your current cluster:
You can access any service directly using port forwarding:
```bash
# Frontend
kubectl port-forward svc/frontend 8080:80 -n development

# ArgoCD UI
kubectl port-forward svc/argocd-server 8443:443 -n argocd

# Grafana UI
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
```

#### Upgrading to an Ingress-Ready Cluster (Optional, for Step 03 / Step 16):
If you want to access workloads directly via `http://localhost` and `http://localhost/api` without manual port forwards, use this configuration:
```yaml
# kind-config-ingress.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
```

---

### 2.2 Storage in KinD (Ready for Step 05 & Stateful Workloads)

KinD comes pre-configured with Rancher's `local-path-provisioner`:
```bash
kubectl get storageclass
# NAME                 PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
# standard (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
```

- Any PVC requesting `storageClassName: standard` (or leaving it default) will automatically dynamically provision volumes backed by the node's Docker filesystem.
- Perfect for:
  - Step 05: StatefulSet testing
  - Step 07: Prometheus TSDB persistence
  - Step 12: Strimzi Kafka brokers
  - Step 30: HashiCorp Vault Raft storage

---

### 2.3 Metrics Server in KinD (Required for HPA / Step 04)

KinD nodes use self-signed kubelet TLS certificates. Metrics Server needs `--kubelet-insecure-tls` to read CPU/memory:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args="{--kubelet-insecure-tls}"

# Verify after 30 seconds:
kubectl top nodes
kubectl top pods -A
```

---

## 3. GitOps Repository Layout for Local vs. AWS

In `Gitops/bootstrap/envs/dev`, your setup includes cloud-dependent controllers:
- `aws-lb-controller-dev.yaml` (needs AWS IAM & VPC)
- `karpenter-dev.yaml` (needs AWS EC2 APIs & IAM roles)
- `external-secrets-operator-dev.yaml` (needs AWS Secrets Manager)

### Recommended: Add a Local Overlay

Create `bootstrap/envs/local/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../projects/platform.yaml
  - ../../projects/dev.yaml
  - ../../projects/metrics-server.yaml
  - ../../projects/prometheus-stack.yaml
  - ../../projects/loki.yaml
  - ../../projects/promtail.yaml
```

This ensures your local KinD cluster runs the core applications and observability stack without crashing on AWS-specific IAM controllers.

---

## 4. Phase-by-Phase Roadmap Execution in KinD

### Phase A: Core Kubernetes (Steps 01 – 06)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **01** | `01-k8s-rbac` | Create `ServiceAccount`, `Role`, `RoleBinding`, `ClusterRole`. Test permissions with `kubectl auth can-i --as=system:serviceaccount:development:frontend`. Test `ResourceQuota` and `LimitRange`. |
| **02** | `02-production-workloads` | Add `readinessProbe`, `livenessProbe`, `startupProbe`, `PodDisruptionBudget`, `topologySpreadConstraints` (across nodes), and `securityContext` (`runAsNonRoot`). Drain a worker node (`kubectl drain dev-lab-worker --ignore-daemonsets`) and watch traffic survive. |
| **03** | `03-ingress-tls-dns` | **Local**: Install `ingress-nginx` or Kong. Issue self-signed certs with `cert-manager`.<br>**Cloud**: Later run external-dns + Route53 + ACM on AWS EKS. |
| **04** | `04-autoscaling` | **Local**: Metrics Server + HPA on CPU/memory. Generate load with busybox `wget` loop; watch pods scale from 2 to 10.<br>**Cloud**: Karpenter EC2 spot provisioning. |
| **05** | `05-storage-statefulsets` | Deploy a StatefulSet (e.g., PostgreSQL or Redis) with `volumeClaimTemplates` using `storageClassName: standard`. Kill a pod, confirm data persistence and stable hostname (`pod-0`). |
| **06** | `06-helm-authoring` | Write `charts/microservice/`. Test locally with `helm lint`, `helm template`, and `helm unittest`. Deploy into KinD using `helm upgrade --install`. |

---

### Phase B: Observability (Steps 07 – 11)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **07** | `07-prometheus-grafana` | Deploy `kube-prometheus-stack`. Set up `ServiceMonitor` for `frontend`, `order-service`, and `user-service`. Port-forward Grafana (`3000:80`). Build dashboards with PromQL. |
| **08** | `08-alerting-slo` | Write `PrometheusRule` CRDs (high error rate, burn rate). Configure Alertmanager with Slack/Discord webhook. Deliberately break a pod and verify the alert fires. |
| **09** | `09-elk-logging` / Loki | Deploy Promtail + Loki (or ECK / Fluent Bit). Ship JSON logs with correlation IDs. Query logs in Grafana. |
| **10** | `10-tracing-otel` | Instrument apps with OpenTelemetry SDK. Deploy OTel Collector and Grafana Tempo in KinD. Trace request path: `frontend` → `order-service` → `user-service`. |
| **11** | `11-synthetic-blackbox` | Deploy Prometheus `blackbox_exporter`. Probe internal/external endpoints for HTTP 200, TLS expiry, and latency. |

---

### Phase C: Event Streaming & Autoscaling (Steps 12 – 15)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **12** | `12-kafka-strimzi` | Install Strimzi operator via Helm. Deploy a 3-broker KRaft Kafka cluster on KinD workers with PVCs. Create `KafkaTopic` and `KafkaUser`. Produce/consume messages. Kill a broker to test ISR resilience. |
| **13** | `13-kafka-ecosystem` | Deploy Apicurio / Confluent Schema Registry. Deploy Kafka Connect. Run an Outbox pattern simulation. |
| **14** | `14-msk-managed` | *AWS only (timebox 1 hr with MSK Serverless).* |
| **15** | `15-keda-autoscaling` | Install KEDA in KinD. Add `ScaledObject` targeting Kafka consumer lag. Produce 5,000 messages; watch consumers scale from 0 → 8 → 0. |

---

### Phase D: API Gateway & Service Mesh (Steps 16 – 19)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **16** | `16-kong-gateway` | Deploy Kong Ingress Controller in DB-less mode in KinD. Route `/api/orders` and `/api/users`. Compare with K8s Gateway API (`HTTPRoute`). |
| **17** | `17-kong-plugins` | Enable plugins: rate limiting (backed by Redis container), key-auth, JWT validation, CORS, request transformation. |
| **18** | `18-service-mesh` | Install Linkerd or Istio in KinD. Mesh namespaces. Verify mTLS between services using `linkerd viz` or `istioctl`. Test 90/10 traffic splitting. |
| **19** | `19-network-policies` | Install Calico or Cilium in KinD. Create default-deny NetworkPolicies. Allow only legitimate microservice-to-microservice traffic. |

---

### Phase E: Progressive Delivery (Steps 20 – 22)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **20** | `20-argo-rollouts` | Install Argo Rollouts controller + kubectl plugin. Replace `Deployment` with `Rollout`. Configure canary release (10% → 25% → 50% → 100%) with `AnalysisTemplate` querying Prometheus. Simulate bad deployment; watch auto-rollback. |
| **21** | `21-argo-workflows-events` | Deploy Argo Workflows. Build a DAG pipeline (build → test → scan). Set up MinIO in KinD for artifact storage. |
| **22** | `22-feature-flags` | Deploy Unleash in KinD. Toggle features dynamically in `frontend` without redeployment. |

---

### Phase F & G: Data & Security (Steps 24 – 32)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **24** | `24-db-migrations` | Run Flyway as an ArgoCD PreSync hook Job against a PostgreSQL container in KinD. Practice expand-contract schema changes. |
| **26** | `26-dynamodb-caching` | Run Redis in KinD. Test cache-aside, cache invalidation, and thundering herd mitigations. |
| **27** | `27-pod-security-policy` | Enforce Pod Security Standards (`restricted`). Install Kyverno; write policies blocking `:latest` tags, requiring non-root, and auto-injecting NetworkPolicies. |
| **28** | `28-supply-chain` | Run Trivy vulnerability scans in CI. Sign images with Cosign. Enforce signature verification at admission via Kyverno. |
| **29** | `29-runtime-security` | Install Falco with eBPF in KinD. Exec into a pod or touch `/etc/shadow`; verify alert triggers. |
| **30** | `30-vault` | Deploy HashiCorp Vault in HA mode (3 replicas with Raft storage). Configure Kubernetes authentication and dynamic secrets. |
| **32** | `32-compliance-benchmarks` | Run `kube-bench` and `kube-hunter` against KinD to audit cluster configuration. |

---

### Phase H & I: Resilience, Testing & Cost (Steps 35 – 41)

| Step | Topic | Local KinD Execution |
|---|---|---|
| **35** | `35-sonarqube-gates` | Run SonarQube in KinD. Gate code PRs on 80% coverage and zero vulnerabilities. |
| **39** | `39-chaos-engineering` | Install Chaos Mesh in KinD. Run experiments: pod kills, network latency injection, packet loss. Observe SLO impact in Grafana. |
| **40** | `40-load-testing` | Run k6 as a K8s Job. Execute ramp-up, spike, and soak tests. Measure bottleneck thresholds. |
| **41** | `41-cost-optimization` | Install OpenCost / Kubecost in KinD. Understand CPU/memory cost attribution per namespace. |

---

## 5. Daily Local Workflow Checklist

When starting a study session:

```bash
# 1. Verify cluster is running
kubectl get nodes

# 2. Check cluster resource consumption on Docker
docker stats --no-stream

# 3. Create or switch to the lesson branch
git checkout -b <lesson-name>

# 4. Implement manifests, apply to KinD, and verify
kubectl apply -k <path-to-overlay>

# 5. Break it intentionally to verify resilience & alerting
kubectl delete pod -l app=order-service
kubectl drain dev-lab-worker --ignore-daemonsets

# 6. Document your findings
echo "### $(date) - Notes on <lesson-name>" >> NOTES.md

# 7. Commit & push branch
git commit -am "Complete <lesson-name>"
```

### When to turn off the cluster:
You don't even need to delete the cluster between sessions! You can simply pause the Docker containers:
```bash
# Pause cluster (saves CPU and battery on Mac):
docker stop dev-lab-control-plane dev-lab-worker dev-lab-worker2

# Resume cluster:
docker start dev-lab-control-plane dev-lab-worker dev-lab-worker2
```
Or destroy and recreate in 30 seconds:
```bash
kind delete cluster --name dev-lab
kind create cluster --name dev-lab --config kind-config.yaml
```
