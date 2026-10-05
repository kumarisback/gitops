# What's Wrong — `tf` + `gitops` repos

Full re-check against the current state of both repos on 2026-08-13. There's an older
[`tf/TERRAFORM_REVIEW.md`](tf/TERRAFORM_REVIEW.md) dated 2026-08-11 — several of its
findings have since been fixed; this file reflects **current code**, notes what changed,
and adds new findings the old review didn't cover (mainly around GitOps/destroy behavior).

Severity: 🔴 Critical  🟠 High  🟡 Medium  ⚪ Already fixed (informational)

---

## 🔴 Critical

### 1. Orphaned AWS Load Balancer blocks NAT Gateway / subnet destroy — **FIXED this session**
`02-services/main.tf` deploys ArgoCD's `root-app` Application, which syncs a `frontend`
Service of `type: LoadBalancer` from the `gitops` repo. Deleting the ArgoCD `Application`
object (what `terraform destroy` does) did **not** cascade-delete the resources it
manages, so the real AWS ELB and its ENIs were left behind in the public subnet, blocking
NAT Gateway / subnet deletion in Layer 1.
**Fix applied:** added `finalizers = ["resources-finalizer.argocd.argoproj.io"]` to the
`root-app` Application in [`tf/infrastructure/app-cluster/02-services/main.tf:49`](tf/infrastructure/app-cluster/02-services/main.tf#L49).
**Still worth doing:** if a prior destroy already got stuck, the orphaned ELB from that run
must be deleted manually once before the next destroy will succeed. Consider also adding a
"delete all `type: LoadBalancer` Services" safety step in the Jenkinsfile before Layer 2
destroy, in case anyone bypasses ArgoCD directly.

### 2. Jenkins IAM role is near-account-admin
[`tf/modules/jenkins/main.tf:31-54`](tf/modules/jenkins/main.tf#L31-L54) attaches an inline
policy granting `ec2:*`, `eks:*`, `iam:*`, `rds:*`, `elasticache:*`, `secretsmanager:*`,
`ssm:*`, `dynamodb:*` on `Resource: "*"`, on top of `AmazonEC2ContainerRegistryPowerUser`
and `AmazonS3FullAccess`. `iam:*` alone means Jenkins can create/attach any policy to any
role, including escalating itself to full `AdministratorAccess` — functionally this is the
same "Jenkins compromise = full account compromise" risk the old review flagged for the
literal `AdministratorAccess` attachment, just renamed.
**Fix:** scope to the specific actions Terraform actually needs (EC2/EKS/RDS/ElastiCache
resource CRUD, S3 read/write only on the state bucket/prefix, DynamoDB only on the lock
table, no `iam:*` — grant only `iam:PassRole`/`CreateRole`/`AttachRolePolicy` scoped to the
`*-eks-*-role`/`*-jenkins-*` name prefixes). Prefer Jenkins assuming a scoped
per-environment deploy role (the `terraform_deploy_role_arns` mechanism already exists in
the module but defaults to `[]` and is unused by every tfvars file today).

### 3. Jenkins & ArgoCD publicly exposed by default, including in prod
- Jenkins SSH (22) and web UI (8080): [`tf/modules/jenkins/main.tf:84-100`](tf/modules/jenkins/main.tf#L84-L100),
  driven by `jenkins_allowed_cidrs = ["0.0.0.0/0"]` in [`shared-services.tfvars:8`](tf/environments/shared-services/shared-services.tfvars#L8).
- ArgoCD UI LoadBalancer: `enable_argocd_loadbalancer = true` + `argocd_allowed_cidrs =
  ["0.0.0.0/0"]` in **all three** [`dev.tfvars:19-20`](tf/environments/app-cluster/dev.tfvars#L19-L20),
  [`staging.tfvars:26-27`](tf/environments/app-cluster/staging.tfvars#L26-L27), and
  [`prod.tfvars:26-27`](tf/environments/app-cluster/prod.tfvars#L26-L27) — despite the
  comment directly above each saying "before real use, replace this."
Anyone on the internet can reach an SSH port, a CI server, and an admin GitOps UI. EKS API
public access is properly restricted for staging/prod (fixed since the old review), but
Jenkins and ArgoCD were missed.
**Fix:** default these CIDR lists to `[]`, require an explicit override, and add a
`validation` block that rejects `0.0.0.0/0` when `environment == "prod"` (the same pattern
already used for `eks_public_access_cidrs`).

---

## 🟠 High

### 4. Broken state locking config for staging & prod
[`tf/environments/app-cluster/staging-backend.hcl:4`](tf/environments/app-cluster/staging-backend.hcl#L4)
and [`prod-backend.hcl:4`](tf/environments/app-cluster/prod-backend.hcl#L4) set
`use_lockfile = "staging"` / `use_lockfile = "prod"`. `use_lockfile` is a **boolean**
(S3-native locking, Terraform ≥1.10) — passing an environment name string there is a type
mismatch and will fail `terraform init`/`plan` for staging and prod. Meanwhile
`dev-backend.hcl` and `shared-services-backend.hcl` use the older `dynamodb_table`
mechanism instead. The two locking strategies are inconsistent across environments and the
staging/prod ones look broken outright.
**Fix:** pick one locking strategy for all environments. Either `dynamodb_table = "<env>"`
everywhere (matches dev/shared-services), or `use_lockfile = true` everywhere (native S3
locking, no DynamoDB table needed) — not a string value in either case.

### 5. Jenkins has no reliable network path to staging/prod EKS clusters
`shared-services` and every `app-cluster` environment create **separate VPCs** with no
peering, Transit Gateway, or VPN between them
([`tf/infrastructure/shared-services/main.tf:31-46`](tf/infrastructure/shared-services/main.tf#L31-L46)
vs. [`tf/infrastructure/app-cluster/01-infra/main.tf:1-11`](tf/infrastructure/app-cluster/01-infra/main.tf#L1-L11)).
Jenkins can only reach a cluster's control plane through its **public** EKS endpoint.
Staging and prod both set `eks_endpoint_public_access = false`, so Jenkins has **no path at
all** to run `helm`/`kubectl`/Layer 2 Terraform against those clusters. Dev works only
because `eks_public_access_cidrs` is pinned to a single hardcoded IP
(`3.80.161.127/32` in [`dev.tfvars:14`](tf/environments/app-cluster/dev.tfvars#L14)) that
has to happen to match Jenkins' current public IP — Jenkins has no Elastic IP
(`associate_public_ip_address = true` only, no `aws_eip`), so this will drift the moment the
instance is replaced.
**Fix:** either VPC-peer shared-services to each app-cluster VPC (or use a Transit Gateway),
or give Jenkins an EIP and use that EIP (not a hand-guessed address) as the allowed CIDR —
but that still doesn't solve staging/prod having public access disabled entirely. Peering/
Transit Gateway is the only approach that works for all three environments.

### 6. External Secrets Operator is referenced but never installed
[`gitops/platform/external-secrets.yaml`](gitops/platform/external-secrets.yaml) defines a
`ClusterSecretStore` and an `ExternalSecret`, but nothing — not Terraform, not
`platform/kustomization.yaml` — actually installs the External Secrets Operator (its CRDs
and controller). These CRs will fail to reconcile; the comment in the file even says "Make
sure the ESO helm chart is installed by ArgoCD or Kustomize," but it isn't, anywhere.
**Fix:** add a `helm_release` for the `external-secrets` chart (either in `02-services` next
to the ArgoCD install, or as its own ArgoCD Application under `platform/`).

### 7. No IRSA/OIDC set up for the cluster at all
`modules/eks/main.tf` never creates an `aws_iam_openid_connect_provider` for the cluster's
OIDC issuer, and no IAM role exists for a service account. Yet
`external-secrets.yaml`'s `ClusterSecretStore.spec.provider.aws.auth.jwt.serviceAccountRef`
(`external-secrets-sa` in `kube-system`) assumes IRSA-style auth. Even once ESO is
installed (#6), it has no way to authenticate to Secrets Manager.
**Fix:** add the OIDC provider (`aws_iam_openid_connect_provider` off
`aws_eks_cluster.this.identity[0].oidc[0].issuer`) plus an IRSA role trust-policy scoped to
the `external-secrets-sa` service account, and grant it `secretsmanager:GetSecretValue`
scoped to the relevant secret ARNs.

### 8. `platform/aws-lb-controller.yaml` doesn't install anything
It's a bare placeholder `ConfigMap`
([`gitops/platform/aws-lb-controller.yaml`](gitops/platform/aws-lb-controller.yaml)) — no
Helm release, no IAM role, no webhook, no CRDs. Currently harmless because nothing uses an
`Ingress` (the `frontend` Service is a plain `type: LoadBalancer`, handled by the in-tree
cloud provider), but the filename actively implies the controller exists when it doesn't —
the moment anyone adds an `Ingress`, it will silently do nothing.
**Fix:** either install the real `aws-load-balancer-controller` Helm chart (with its own
IRSA role, which also needs #7's OIDC provider) or delete the placeholder and rename
expectations in the README.

### 9. `apps/prod/app-secrets.yaml` is dead code, and wrong even if wired in
[`gitops/apps/prod/kustomization.yaml`](gitops/apps/prod/kustomization.yaml) only lists
`../base` under `resources:` — `app-secrets.yaml` sitting in the same directory is never
included, so it's never applied. Separately, even if it were wired in, its
`ExternalSecret.spec.secretStoreRef` points at `name: secret-store, kind: SecretStore` — but
the only store that exists anywhere is `ClusterSecretStore/aws-secretsmanager` (defined in
`platform/external-secrets.yaml`). Name and kind both mismatch; it would never resolve.
**Fix:** add `app-secrets.yaml` to `apps/prod/kustomization.yaml`'s `resources:`, and change
`secretStoreRef` to `name: aws-secretsmanager, kind: ClusterSecretStore`.

---

## 🟡 Medium

### 10. Undeclared / dead variable `eks_endpoint_private_access`
[`dev.tfvars:13`](tf/environments/app-cluster/dev.tfvars#L13) sets
`eks_endpoint_private_access = true`, but no such variable is declared in
`01-infra/variables.tf` — Terraform will warn ("value for undeclared variable") and ignore
it. Even if it were declared and wired through, `modules/eks/main.tf:100` hardcodes
`endpoint_private_access = true` unconditionally, so the value could never actually change
anything.
**Fix:** remove the stray line from `dev.tfvars`, or properly parameterize
`endpoint_private_access` in the eks module if per-environment control is ever needed.

### 11. Stale/orphaned backend file
[`tf/environments/app-cluster/dev-backend.hcl`](tf/environments/app-cluster/dev-backend.hcl)
(key `dev/terraform.tfstate`) doesn't match the two-layer split used everywhere else
(`dev-infra-backend.hcl` → `dev/infrastructure.tfstate`,
`dev-services-backend.hcl` → `dev/services.tfstate`) and isn't referenced by the Jenkinsfile
or any root module. Looks like a leftover from before the 01-infra/02-services split.
**Fix:** delete it, or document why it's kept.

### 12. Inconsistent per-env secret provisioning pattern
Dev's DB secret comes from an `ExternalSecret` embedded directly in
`platform/external-secrets.yaml` (namespace `development`); prod has its own (broken, see
#9) `ExternalSecret` under `apps/prod/`; staging has neither. There's no single consistent
place/pattern for "how does an environment get its secrets."
**Fix:** pick one pattern (e.g., one `ExternalSecret` per environment under
`apps/<env>/app-secrets.yaml`, none of them inlined into `platform/`) and apply it uniformly
to dev/staging/prod.

### 13. Committed Terraform plan file
[`tf/infrastructure/shared-services/tfplan`](tf/infrastructure/shared-services/tfplan) is
tracked in git (confirmed via `git ls-files`). Binary plan files shouldn't be
version-controlled — they can go stale immediately, bloat the repo, and can contain
sensitive values (resource attributes, sometimes secrets) in plaintext.
**Fix:** `git rm --cached infrastructure/shared-services/tfplan` and add `*.tfplan` /
`tfplan` to `.gitignore` (check it isn't already covered).

### 14. Single NAT Gateway per environment (no HA)
[`tf/modules/networking/main.tf:76-86`](tf/modules/networking/main.tf#L76-L86) creates one
NAT Gateway in `public[0]` only; both private route tables share it. Fine for dev to save
cost, but it's a single-AZ dependency for staging/prod with no way to opt into one-NAT-per-AZ.
**Fix (if/when HA matters):** one NAT + EIP per AZ, one private route table per AZ,
selected via a variable so dev can stay cheap.

### 15. EKS node group has no production hardening knobs
[`tf/modules/eks/main.tf:114-131`](tf/modules/eks/main.tf#L114-L131) — single
`instance_types` entry, no `capacity_type`, no launch template (so no IMDSv2 enforcement, no
custom disk size), no labels/taints, no `update_config`.
**Fix:** expose these as module variables; at minimum enforce IMDSv2 via a launch template.

### 16. Sole cluster admin for staging/prod is the Jenkins role
`eks_admin_users` is `[]` for both [`staging.tfvars:22`](tf/environments/app-cluster/staging.tfvars#L22)
and [`prod.tfvars:22`](tf/environments/app-cluster/prod.tfvars#L22)
(not set — defaults to `[]`). Combined with
`bootstrap_cluster_creator_admin_permissions = true`, the only entity with cluster-admin on
staging/prod is whatever ran `terraform apply` — i.e., the Jenkins role from #2. No human
has been granted access via Terraform.
**Fix:** add real admin/on-call IAM principals to `eks_admin_users` for staging and prod.

---

## ⚪ Already fixed since the 2026-08-11 review (no action needed)

For reference against [`tf/TERRAFORM_REVIEW.md`](tf/TERRAFORM_REVIEW.md) — these no longer
apply to current code:

- **EKS API open to `0.0.0.0/0`**: `modules/eks/variables.tf` now has a `validation` block
  rejecting `0.0.0.0/0`, and prod/staging set `eks_endpoint_public_access = false`.
- **Secrets managed via `local-exec`/AWS CLI**: `modules/secrets/main.tf` now uses native
  `aws_secretsmanager_secret` / `aws_secretsmanager_secret_version` resources.
- **RDS/Redis SSM parameter name-value mismatch**: `01-infra/main.tf` now writes
  `rds_endpoint` and `redis_endpoint` to their own correctly-named SSM parameters.
- **Shared-services had no remote backend**: it now has `backend "s3" {}` plus a filled-in
  `shared-services-backend.hcl`.
- **Unsafe RDS defaults** (`skip_final_snapshot=true`, `deletion_protection=false`, default
  password): `01-infra/variables.tf` now defaults to `rds_deletion_protection = true`,
  `rds_skip_final_snapshot = false`, `rds_storage_encrypted = true`, and requires an explicit
  password or `rds_manage_master_user_password = true` (enforced via a `precondition`).
- **Prod/staging tfvars empty**: both are now fully filled in (though see #4 for a new bug
  introduced in their backend configs).
- **Terraform version inconsistency**: root modules now require `>= 1.12, < 2.0`, matching
  the `1.12.2` Jenkins installs.

---

## Suggested fix order

1. #2, #3 — cut Jenkins' IAM blast radius and close public SSH/8080/ArgoCD exposure (highest
   real-world risk).
2. #4 — fix staging/prod backend locking before anyone runs `terraform init` there again.
3. #1 — already done.
4. #5 — decide on VPC peering/Transit Gateway so Jenkins can actually reach staging/prod.
5. #6, #7, #8 — either finish wiring ESO + IRSA + the LB controller, or remove the
   placeholders so the repo doesn't claim capabilities it doesn't have.
6. #9, #10, #11, #12, #13 — cleanup items, low risk, quick wins.
7. #14, #15, #16 — production-hardening backlog, not urgent for dev/learning use.
