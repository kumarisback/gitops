# Infrastructure Architecture — `tf` + `gitops` repos

Updated 2026-08-13 after a round of fixes (Jenkins/ArgoCD IAM scoping, OIDC/IRSA, VPC
peering, node hardening, secret/backend consistency, and removing Jenkins/ArgoCD from
public exposure). Covers what gets created, by which layer, and which IAM roles/policies
attach to what, for every apply/boot path: `shared-services`, `app-cluster`
(`dev` / `staging` / `prod`), and the GitOps sync that follows.

---

## 1. Overall layering

There are **three independent Terraform root modules**, applied in this order by
[`tf/Jenkinsfile`](tf/Jenkinsfile), plus a GitOps layer that ArgoCD drives after Layer 2:

```mermaid
flowchart LR
    SS["infrastructure/shared-services\n(Jenkins + ECR + its own VPC)"]
    L1["app-cluster/01-infra\n(VPC + EKS + DB + OIDC/IRSA, per env)"]
    L2["app-cluster/02-services\n(ArgoCD + ESO + LB Controller, per env)"]
    GO["gitops repo\n(ArgoCD-driven sync)"]

    SS -->|"VPC peering + remote_state\n(vpc_id, cidr, route tables)"| L1
    L1 -->|"remote_state: infrastructure.tfstate\n(cluster info + irsa_role_arns)"| L2
    L2 -->|"Helm-installs ArgoCD + root Application"| GO
    GO -->|"reconciles workloads into the EKS cluster"| L1
```

`shared-services` is applied **once, first** — every environment's Layer 1 peers to it and
reads its VPC info via remote state. `01-infra`/`02-services` are then applied per
environment (`dev`, `staging`, `prod`), each with its own VPC and its own S3 state key.

---

## 2. `shared-services` apply (Jenkins + ECR)

File: [`tf/infrastructure/shared-services/main.tf`](tf/infrastructure/shared-services/main.tf)

```mermaid
flowchart TD
    subgraph VPC_SS["VPC: shared-services (module.networking)"]
        IGW_SS[Internet Gateway]
        PUB_SS[Public subnets]
        NAT_SS[NAT Gateway]
        PRIVRT_SS[Private route table\n+ peering routes to dev/staging/prod]
        PRIV_SS["Private app subnet\n(Jenkins lives here now — no public IP)"]
        IGW_SS --> PUB_SS
        PUB_SS --> NAT_SS --> PRIVRT_SS --> PRIV_SS
    end

    subgraph ECR["module.ecr"]
        REPO1[ecr: user-service]
        REPO2[ecr: order-service]
        REPO3[ecr: frontend]
        LC[lifecycle policy:\nexpire untagged >14d]
        REPO1 & REPO2 & REPO3 --> LC
    end

    subgraph JENKINS["module.jenkins"]
        JROLE[aws_iam_role: jenkins-role\ntrust: ec2.amazonaws.com]
        JPOL1[AmazonEC2ContainerRegistryPowerUser]
        JPOLSSM[AmazonSSMManagedInstanceCore\n← access path, no open ports]
        JPOLS3["scoped: terraform_state_access\ns3 on state_bucket_names only"]
        JPOL3["scoped: jenkins_terraform_provisioner\nec2:*/eks:*/rds:*/elasticache:* (Resource *)\n+ iam: only role/instance-profile *-name-prefix*\n+ secretsmanager/ssm: this account+region, name-scoped"]
        JPOL4["inline: assume_terraform_deploy_roles\n(only if terraform_deploy_role_arns set —\ndefault [] means unused)"]
        JPROFILE[instance_profile]
        JSG["security_group\nNO ingress rule at all by default\n(allowed_cidr_blocks defaults to [])"]
        JEC2["EC2 instance\nprivate subnet, NO public IP\nuser_data installs:\nterraform, kubectl, helm, docker,\nJava21, Jenkins, checkov, awscli"]

        JROLE --> JPOL1 & JPOLSSM & JPOLS3 & JPOL3 & JPOL4
        JROLE --> JPROFILE --> JEC2
        JSG --> JEC2
    end

    PRIV_SS -->|"private_app_subnet_ids[0]"| JEC2
```

**Key facts**
- Jenkins now lives in shared-services' **private** subnet with **no public IP** and no
  open inbound security-group rule by default. Access is via
  `aws ssm start-session` (see `tf/README.md`, "Step 4").
- Jenkins' IAM role is scoped: broad-but-bounded `ec2:*/eks:*/rds:*/elasticache:*` (needed
  for full provisioning lifecycle), but `iam:*`/`secretsmanager:*`/`ssm:*` are all
  restricted to this project's name prefix and this account/region — no more
  `Resource: "*"` account-wide admin.
- `AmazonSSMManagedInstanceCore` replaces the old open-SSH access path.
- `allowed_cidr_blocks` (default `[]`) can still be set to a VPN/office CIDR if a direct
  network path is ever wanted instead of SSM.

---

## 3. `app-cluster/01-infra` apply (per environment: dev / staging / prod)

File: [`tf/infrastructure/app-cluster/01-infra/main.tf`](tf/infrastructure/app-cluster/01-infra/main.tf)

```mermaid
flowchart TD
    subgraph VPC_ENV["VPC: microservices-<env> (module.networking)"]
        IGW[Internet Gateway]
        PUB["Public subnets\n(2 AZs)"]
        NAT["NAT Gateway(s)\nsingle (dev/staging) or\none-per-AZ (prod: single_nat_gateway=false)"]
        RTPUB[Public route table → IGW]
        RTPRIV["Private route table(s)\n+ peering route to shared-services"]
        PRIVAPP["Private-app subnets\n(2 AZs)"]
        PRIVDATA["Private-data subnets\n(2 AZs)"]

        IGW --> RTPUB --> PUB
        PUB --> NAT --> RTPRIV
        RTPRIV --> PRIVAPP
        RTPRIV --> PRIVDATA
    end

    PEER["aws_vpc_peering_connection\nto shared-services (auto_accept)\n+ routes both directions"]
    PUB -.->|read via remote_state| SHAREDVPC[shared-services VPC/CIDR/route table]
    PEER --- RTPRIV
    PEER --- SHAREDVPC

    subgraph EKS["module.eks"]
        CROLE["aws_iam_role: eks-cluster-role\ntrust: eks.amazonaws.com\n+ AmazonEKSClusterPolicy"]
        NROLE["aws_iam_role: eks-node-role\ntrust: ec2.amazonaws.com\n+ AmazonEKSWorkerNodePolicy\n+ AmazonEKS_CNI_Policy\n+ AmazonEC2ContainerRegistryReadOnly"]
        CSG["security_group: eks-cluster-sg\n(egress-only, all ports out)"]
        CLUSTER["aws_eks_cluster\nendpoint_private_access = true (hardcoded)\nendpoint_public_access = var (dev: true+pinned IP; staging/prod: false)"]
        OIDC["aws_iam_openid_connect_provider\n← NEW: enables IRSA"]
        IRSA_ESO["IRSA role: external_secrets\nsa: kube-system/external-secrets-sa\nsecretsmanager:GetSecretValue on microservices/<env>/*"]
        IRSA_LBC["IRSA role: aws_lb_controller\nsa: kube-system/aws-load-balancer-controller\nofficial AWSLoadBalancerControllerIAMPolicy"]
        LT["aws_launch_template\nIMDSv2 required, gp3 disk,\nno public IP on node ENIs"]
        NODEGROUP["aws_eks_node_group\ncapacity_type/labels/taints/update_config\nvia launch_template"]
        ACCESS["aws_eks_access_entry / access_policy_association\nfor each var.eks_admin_users\n(empty list for staging & prod)"]

        CROLE --> CLUSTER
        CLUSTER --> OIDC --> IRSA_ESO & IRSA_LBC
        NROLE --> LT --> NODEGROUP
        CSG --> CLUSTER
        CLUSTER --> NODEGROUP --> ACCESS
    end

    subgraph DB["module.database (conditional)"]
        RDSSG["aws_security_group: rds-sg\ningress 5432/3306 from VPC CIDR\n(only if enable_rds — false in all envs today)"]
        RDS["aws_db_instance\n(not created — enable_rds=false everywhere)"]
        REDISSG["aws_security_group: redis-sg\ningress 6379 from VPC CIDR"]
        REDIS["aws_elasticache_cluster\n(single node, no HA)"]
    end

    subgraph SECRETS["module.secrets + SSM"]
        SECRET["aws_secretsmanager_secret\napp-config: REDIS_HOST, REDIS_PORT\nrecovery_window_in_days = 0"]
        SSMR["aws_ssm_parameter\n/{env}/redis/endpoint"]
        SSMD["aws_ssm_parameter\n/{env}/rds/endpoint (only if enable_rds)"]
    end

    PRIVAPP -->|"private_subnet_ids"| CLUSTER
    PRIVDATA -->|"private_data_subnet_ids"| DB
    DB --> SECRET
    DB --> SSMR
    DB --> SSMD
```

**Key facts**
- Every environment still gets its **own VPC**, but is now **peered to shared-services**
  (auto-accepted, same-account) so Jenkins has a private network path to each cluster's API
  regardless of `eks_endpoint_public_access`.
- An **OIDC provider** is now registered for the cluster, with a generic `irsa_roles` map
  that creates one scoped IAM role per in-cluster controller (currently
  `external_secrets` and `aws_lb_controller`) — no more permissions borrowed from the node
  role.
- The node group now launches through a **launch template enforcing IMDSv2**, with
  configurable disk size/capacity type/labels/taints/update_config.
- Prod sets `single_nat_gateway = false` — one NAT gateway per AZ instead of a single-AZ
  dependency; dev/staging keep the cheaper single-NAT default.
- `bootstrap_cluster_creator_admin_permissions = true` still means the Terraform-apply
  identity (Jenkins) is always a cluster admin; `eks_admin_users` remains empty for
  staging/prod (add real admin ARNs there if/when needed).

---

## 4. `app-cluster/02-services` apply (ArgoCD + platform add-ons, per environment)

File: [`tf/infrastructure/app-cluster/02-services/main.tf`](tf/infrastructure/app-cluster/02-services/main.tf)

```mermaid
flowchart TD
    RS["data.terraform_remote_state.infra\nreads Layer 1 state:\ncluster_endpoint, cluster_ca_data, cluster_name,\nvpc_id, irsa_role_arns"]
    HELMPROV["helm + kubernetes providers\nauth via `aws eks get-token`"]
    ARGO["helm_release: argocd\nserver.service.type = ClusterIP by default\n(enable_argocd_loadbalancer=false everywhere)"]
    ESO["helm_release: external_secrets\nSA external-secrets-sa annotated with\nIRSA role ARN from Layer 1"]
    LBC["helm_release: aws_lb_controller\nSA aws-load-balancer-controller annotated with\nIRSA role ARN from Layer 1"]
    ROOT["helm_release: argocd_root_app\n(App-of-Apps)\nfinalizers: resources-finalizer.argocd.argoproj.io\n(cascade-deletes GitOps-managed resources on destroy)"]

    RS --> HELMPROV
    HELMPROV --> ARGO
    HELMPROV --> ESO
    HELMPROV --> LBC
    ARGO --> ROOT
    ESO -.->|"CRDs must exist before"| ROOT
    ROOT -->|"source: gitops repo\npath: bootstrap/projects"| GITOPS_SYNC[ArgoCD reconciliation]
```

**Key facts**
- ArgoCD's Service is **ClusterIP by default** in dev/staging/prod — access via
  `kubectl port-forward` (direct for dev, tunneled through Jenkins/SSM for staging/prod,
  since their EKS APIs are private-only). See `tf/README.md` Step 4.
- **External Secrets Operator** and the **AWS Load Balancer Controller** are now actually
  installed here (previously only referenced, never installed, in the gitops repo) — each
  with its own IRSA role from Layer 1, annotated onto the chart's ServiceAccount.
- `argocd_root_app` still carries the cascade-delete finalizer so `terraform destroy`
  cleans up everything ArgoCD deployed (e.g. the `frontend` LoadBalancer's AWS ELB) before
  Layer 1 tears down the VPC/NAT/subnets.

---

## 5. GitOps sync (ArgoCD reconciliation, driven from the `gitops` repo)

```mermaid
flowchart TD
    ROOTAPP["Application: root-app\n(bootstrap/root-app.yaml, path=bootstrap/projects)"]
    DEVAPP["Application: dev-env\n→ apps/dev → ns: development"]
    STAGEAPP["Application: staging-env\n→ apps/staging → ns: staging"]
    PRODAPP["Application: prod-env\n→ apps/prod → ns: production"]
    PLATAPP["Application: platform\n→ platform/ → ns: kube-system"]

    ROOTAPP --> DEVAPP & STAGEAPP & PRODAPP & PLATAPP

    subgraph PLATFORM["platform/ manifests"]
        ESOCR["external-secrets.yaml\nClusterSecretStore: aws-secretsmanager only\n(app-specific ExternalSecrets moved out)"]
    end
    PLATAPP --> ESOCR

    subgraph APPS["apps/<env>/app-secrets.yaml (consistent pattern)"]
        DEVSEC["dev: ExternalSecret → microservices/dev/app-config"]
        STGSEC["staging: ExternalSecret → microservices/staging/app-config"]
        PRODSEC["prod: ExternalSecret → microservices/prod/app-config\n(fixed: correct ClusterSecretStore ref, wired into kustomization)"]
    end
    DEVAPP --> DEVSEC
    STAGEAPP --> STGSEC
    PRODAPP --> PRODSEC

    subgraph BASEAPPS["apps/base (frontend, order-service, user-service)"]
        FSVC["frontend Service\ntype: LoadBalancer\n→ real AWS ELB, NOT tracked by Terraform\n→ cleaned up on destroy via ArgoCD finalizer"]
        OSVC["order-service Service: ClusterIP"]
        USVC["user-service Service: ClusterIP"]
    end
    DEVAPP & STAGEAPP & PRODAPP --> BASEAPPS
```

**Key facts**
- The AWS Load Balancer Controller placeholder (`aws-lb-controller.yaml`) is **removed** —
  the real controller is installed via Terraform/Helm in `02-services` instead (it needs an
  IRSA role only Terraform can create).
- Every environment now follows the **same** `apps/<env>/app-secrets.yaml` pattern, pulling
  from the `microservices/<env>/app-config` Secrets Manager secret that Terraform's
  `modules/secrets` actually creates — no more inconsistent per-env approaches or dangling
  references to secrets/parameters that don't exist.
- `frontend`'s Service is still the one AWS-managed (not Terraform-tracked) resource in the
  whole stack — its lifecycle is now handled correctly by the ArgoCD finalizer on destroy.

---

## 6. Network topology & destroy-time dependency chain

```mermaid
flowchart LR
    subgraph SSVPC["shared-services VPC (10.50.0.0/16)"]
        JENKINS_EC2["Jenkins EC2\nprivate subnet, no public IP"]
    end
    subgraph DEVVPC["dev VPC — 10.10.0.0/16"]
        DEVEKS[EKS API]
    end
    subgraph STGVPC["staging VPC — 10.20.0.0/16"]
        STGEKS[EKS API: private only]
    end
    subgraph PRODVPC["prod VPC — 10.30.0.0/16"]
        PRODEKS[EKS API: private only]
    end

    JENKINS_EC2 <-->|"VPC peering\n(auto-accepted, same account)"| DEVEKS
    JENKINS_EC2 <-->|"VPC peering"| STGEKS
    JENKINS_EC2 <-->|"VPC peering"| PRODEKS
```

Destroy order enforced by `tf/Jenkinsfile` (Layer 2 → Layer 1) is correct, and the ArgoCD
cascade-delete finalizer (§4) now ensures GitOps-managed AWS resources (the `frontend` ELB)
are cleaned up before Layer 1 tries to delete the NAT Gateway/subnets — the original
destroy failure this document was written to diagnose. Jenkins can now reach every
environment's EKS API over private networking regardless of public endpoint access,
closing the network-isolation gap that existed before this round of fixes.

---

## 7. IAM / trust summary

| Role | Trust | Attached / effective permissions | Where |
|---|---|---|---|
| `jenkins-role` | `ec2.amazonaws.com` | ECR PowerUser + SSM Managed Instance Core + scoped S3 (state buckets only) + `ec2:*/eks:*/rds:*/elasticache:*` + name/account/region-scoped `iam:*`/`secretsmanager:*`/`ssm:*` | `modules/jenkins/main.tf` |
| `eks-cluster-role` | `eks.amazonaws.com` | `AmazonEKSClusterPolicy` | `modules/eks/main.tf` |
| `eks-node-role` | `ec2.amazonaws.com` | `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` | `modules/eks/main.tf` |
| `irsa-external_secrets` | OIDC-federated (`system:serviceaccount:kube-system:external-secrets-sa`) | `secretsmanager:GetSecretValue`/`DescribeSecret` on `microservices/<env>/*` | `modules/eks/main.tf` (via `irsa_roles`) |
| `irsa-aws_lb_controller` | OIDC-federated (`system:serviceaccount:kube-system:aws-load-balancer-controller`) | Official `AWSLoadBalancerControllerIAMPolicy` | `modules/eks/main.tf` (via `irsa_roles`) |
| Cluster admin | via `bootstrap_cluster_creator_admin_permissions=true` | Always the Terraform-apply identity (Jenkins role); `eks_admin_users` adds more, but is `[]` for staging/prod | `modules/eks/main.tf` |

---

## 8. Public exposure (current state)

| Component | Exposure | Access path |
|---|---|---|
| Jenkins | None — no public IP, no open inbound port by default | `aws ssm start-session` (see `tf/README.md` Step 4) |
| ArgoCD UI | None — `ClusterIP` by default in every environment | `kubectl port-forward`, direct for dev, tunneled through Jenkins for staging/prod |
| EKS API (dev) | Public, pinned to one CIDR | Direct, if your IP matches `eks_public_access_cidrs` |
| EKS API (staging/prod) | Private only | Via the shared-services peering, from Jenkins or anything else inside that network |
| `frontend` app Service | Public (`type: LoadBalancer`) | Its own AWS ELB hostname — see `gitops/README.md` |

See `tf/README.md`, "Step 5: Granting Roles/Policies, and Making Things Public," for how to
deliberately re-open any of the above, or grant a new service its own scoped access.
