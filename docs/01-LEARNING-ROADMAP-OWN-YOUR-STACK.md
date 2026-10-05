# Roadmap 01 — Own What's Already Built

**Read this file first. `LEARNING-ROADMAP.md` is roadmap 02 — start it only after finishing this one.**

---

## Why this file exists

Most of what's in your `tf` + `gitops` repos was built with AI assistance. That's a perfectly
fine way to *build* — but it means the code exists and works while the understanding doesn't
yet. And roadmap 02 (Kafka, Kong, ELK, service mesh, etc.) assumes that understanding as its
foundation.

So this file is **retroactive**. It adds nothing new. It takes the twelve things already
sitting in your repos and makes each one genuinely yours, in dependency order — roughly the
order they were actually built.

Don't skip it because it looks like "stuff I already did." You didn't do it — you *directed*
it. That's a different thing, and the gap shows up the first time production breaks at 2am
and there's no AI-shaped answer to "why is the NAT gateway in that subnet?"

The good news: you have a real, working, non-trivial platform to learn from. That's a much
better classroom than any tutorial, and most beginners don't have one.

---

## The one technique that makes this work

For each of the twelve steps, the test is **not** "can I read this code and nod along." It's:

> **Delete it. Rebuild it from a blank file without looking at the original.**
> Then `diff` your version against what's in the repo and explain every single difference.

Work in a scratch directory (`~/scratch/learn-NN/`), never in the repo. You *will* get it
wrong the first time — that is the entire point. The gaps you hit are precisely the things
you didn't actually know. AI can explain a concept to you; only rebuilding proves you
absorbed it.

Second technique, equally important: **explain it out loud to nobody**, in plain language,
without notes. If you stall mid-sentence, you've found a gap. Write it in `NOTES.md` and go
look it up.

> **The rule for this whole file: you may ask AI to *explain* and to *quiz you*. You may not
> ask it to write the rebuild.** If you paste in a request for code, that step is wasted —
> you'll have produced another artifact you don't understand, which is the exact problem
> this file exists to fix.

---

## Branch workflow

One branch per step, in whichever repo it touches, same name in both when it spans both:

```bash
git checkout main && git pull
git checkout -b 07-kubernetes-by-hand
# ... work, commit as you go ...
git push -u origin 07-kubernetes-by-hand
```

**Deliverable per branch:** your from-scratch rebuild plus `docs/learn/NN-<topic>.md` — an
explanation of the existing code in your own words. Writing the explanation is not busywork;
it's the highest-signal test there is. You cannot write a clear explanation of something you
don't understand, and trying shows you exactly where the fog is.

**Gotcha for `gitops` branches:** ArgoCD syncs whatever `argocd_gitops_repo_revision` points
at — currently `"HEAD"` (= `main`). A branch in `gitops` is **invisible** to ArgoCD until you
point that at your branch in `environments/app-cluster/dev.tfvars` and re-apply Layer 2, or
merge to `main`.

**Numbering note:** roadmap 02 also starts its branches at `01`. When you get there, continue
its numbering from **13** onward so branch names stay unique across both files.

---

## Cost discipline — read before you spin anything up

You're learning in a **real AWS account with real billing**. Rules:

1. **Destroy at the end of every session.** Your pipeline already has a `destroy` action. `terraform destroy` is a learning tool, not a failure.
2. **Only run `dev`.** Never `staging`/`prod` in this file.
3. **Keep `single_nat_gateway = true`** (~$32/mo each, billed even when idle).
4. **Use Spot** for node groups — `node_capacity_type = "SPOT"`, the variable already exists. ~70% cheaper.
5. **Set an AWS Budget alert at $50 today**, before step 01. Console → Billing → Budgets.
6. **`kubectl get svc -A | grep LoadBalancer` before destroying.** Every LoadBalancer Service = a real ELB = real money, and (as you found out) can block VPC teardown.
7. 💰-flagged steps involve real hourly cost. Build, verify, screenshot, destroy same day.

---

## Prerequisites (study, no branch) — ~2 weeks

These will bite you constantly if shaky.

**Linux & processes**
- `systemd` (why `systemctl enable` ≠ `start`), reading `journalctl -u <svc>`
- Signals: `SIGTERM` vs `SIGKILL` — this directly explains K8s pod shutdown
- Permissions, users/groups (explains `usermod -aG docker jenkins` in your Jenkins user_data)
- cgroups & namespaces — *this is literally what a container is*
- **Exercise:** SSM into Jenkins, diagnose a failed service using only `journalctl`

**Networking**
- CIDR math — answer "how many usable IPs in `10.10.1.0/24`?" instantly. Your whole VPC rests on this
- DNS resolution order; A vs CNAME
- TCP handshake, ports, NAT
- TLS handshake, certificate chains, why self-signed warns
- **Exercise:** trace a packet from your laptop → `frontend` load balancer → pod → Redis. Name every hop.

**Docker**
- Multi-stage builds, layer caching, `.dockerignore`
- Distroless / Alpine / scratch tradeoffs
- Why `latest` is dangerous (`apps/dev` uses `newTag: "latest"` — know exactly why that's a problem)
- Non-root users, build args vs env vars
- **Exercise:** get one service's image under 100MB with a multi-stage build

**Git beyond commit/push**
- `rebase -i`, `cherry-pick`, `bisect`, `reflog`, `stash`
- **Why:** you're about to create 12 branches here and 43 more later

---

## Progress tracker

| # | Branch | Topic | 💰 | Est. | Done |
|---|---|---|---|---|---|
| 01 | `01-terraform-fundamentals` | HCL, state, backends, the 3-layer split | | 1.5w | ☐ |
| 02 | `02-vpc-networking` | VPC, subnets, IGW, NAT, route tables, peering | | 2w | ☐ |
| 03 | `03-iam-deep-dive` | Roles, policies, trust, instance profiles | | 1.5w | ☐ |
| 04 | `04-ecr-and-images` | ECR, tags vs digests, layers, lifecycle | | 1w | ☐ |
| 05 | `05-jenkins-provisioning` | EC2, user_data, cloud-init, SSM access | 💰 | 1.5w | ☐ |
| 06 | `06-eks-cluster` | Control plane, node groups, launch templates | 💰 | 2.5w | ☐ |
| 07 | `07-kubernetes-by-hand` | Pods, Deployments, Services, DNS, debugging | 💰 | 2.5w | ☐ |
| 08 | `08-kustomize` | Bases, overlays, patches, transformers | | 1w | ☐ |
| 09 | `09-argocd-gitops` | Reconciliation, App-of-Apps, finalizers | 💰 | 2w | ☐ |
| 10 | `10-data-layer-secrets` | ElastiCache, RDS module, Secrets Manager, ESO | 💰 | 1.5w | ☐ |
| 11 | `11-irsa-oidc` | OIDC, JWT, AssumeRoleWithWebIdentity | 💰 | 2w | ☐ |
| 12 | `12-pipeline-and-the-destroy-bug` | Jenkinsfile, layer ordering, the real root cause | 💰 | 1.5w | ☐ |

**Total: ~2.5–3 months** at 8–10 hrs/week, plus 2 weeks of prerequisites.

---

# The twelve steps

## 01 — `01-terraform-fundamentals`

**What's already in your repo:** three root modules (`infrastructure/shared-services`,
`infrastructure/app-cluster/01-infra`, `02-services`), six reusable modules under `modules/`,
S3 remote state with native locking, per-environment tfvars and backend configs.

**Prove you understand it**
- Why *three separate root modules* instead of one? What does the split buy you, and what does it cost? (Blast radius — and the `terraform_remote_state` reads it forces.)
- What is Terraform *state*, physically? Open your state file in S3 and look at it. Why does it need locking? What happens concretely if two applies run simultaneously?
- Why `use_lockfile = true` rather than a DynamoDB table? What changed in Terraform to make that possible?
- Explain `resource` vs `data` vs `module` vs `variable` vs `output` vs `locals` — one sentence each.
- In `modules/networking/main.tf`: explain `count` vs `for_each` vs `dynamic` blocks and why each was used where it was.
- What does `terraform plan` actually do? Name the three things it reconciles.

**Do**
1. In a scratch dir, from a blank file: a root module with an S3 backend that creates one S3 bucket. No copying. Get `init`/`plan`/`apply`/`destroy` working end to end.
2. Break it: corrupt your local state, recover from S3 version history. Then delete a resource in the console and run `plan` — see drift for the first time.
3. Practice `state list`, `state show`, `import`, `moved` blocks, `-replace`.
4. Read `modules/networking/main.tf` line by line; write `docs/learn/01-terraform.md` explaining every block in your own words.
5. `terraform graph | dot -Tpng > graph.png` on `01-infra`; trace the dependency order.

**~1.5 weeks.**

---

## 02 — `02-vpc-networking`

**What's already in your repo:** [`modules/networking/`](tf/modules/networking/) — VPC, 2
public + 2 private-app + 2 private-data subnets across AZs, IGW, NAT gateway(s), public and
private route tables, associations, and VPC peering to shared-services.

**Prove you understand it**
- Draw your dev VPC from memory: every subnet, its CIDR, its AZ, its route table, and where its default route points. Then check against the code.
- Why *three* subnet tiers? What is "private-data" protecting against that "private-app" isn't?
- A pod in private-app calls `api.github.com` — trace every hop. Now the reverse: something on the internet tries to reach that pod. Where exactly does it fail, and why?
- What does the NAT Gateway do that the IGW doesn't? Why can't private subnets just use the IGW?
- `10.10.0.0/16` split into `/24`s — how many, how many usable IPs each? Why does AWS reserve 5 per subnet?
- Why does an EKS subnet need `kubernetes.io/role/elb` tags? What breaks *silently* without them?
- `single_nat_gateway = true` vs `false` — draw both. What exactly fails in single-NAT mode when one AZ dies?

**Do**
1. From scratch: VPC + 2 public + 2 private subnets + IGW + NAT + route tables. No copying. Launch an EC2 instance in each tier and prove connectivity matches your predictions.
2. Deliberately misconfigure: remove the private route table's NAT route. Watch what breaks. Fix it.
3. `diff` your rebuild against `modules/networking/main.tf`. Explain every difference — some are your bugs, some are things the module does that you didn't think of.
4. `docs/learn/02-networking.md` with your VPC diagram (Mermaid or ASCII) and the packet-path traces.

**~2 weeks.** The most important step in this file. Networking confusion is the root cause of
most "why doesn't this work" in cloud infrastructure.

---

## 03 — `03-iam-deep-dive`

**What's already in your repo:** the Jenkins role and its four policies
([`modules/jenkins/main.tf`](tf/modules/jenkins/main.tf)), EKS cluster + node roles
([`modules/eks/main.tf`](tf/modules/eks/main.tf)), instance profiles, EKS access entries.

**Prove you understand it**
- Role vs policy vs instance profile vs trust policy — four sentences, no hedging.
- What does `assume_role_policy` actually mean? Why does the EKS cluster role trust `eks.amazonaws.com` while the node role trusts `ec2.amazonaws.com`?
- Why does an EC2 instance need an *instance profile* rather than a role attached directly?
- Read every `Statement` in `jenkins_terraform_provisioner`. For each: what does it allow, on which resources, and *why is it scoped that way*? Why is `ec2:*` acceptable but `iam:*` was not?
- What is a **service-linked role**, and why did your pipeline fail with `iam:GetRole` denied on `AWSServiceRoleForAmazonEKSNodegroup`? (You hit this for real — make sure you can explain it.)
- Why can't `ssm:DescribeParameters` be scoped to a specific parameter ARN?
- Explain an ARN's segments: `arn:aws:iam::123456789012:role/foo`. Which services include a region, which don't, and why?
- Identity-based vs resource-based policies — which is an S3 bucket policy?
- Policy evaluation: explicit deny > explicit allow > implicit deny. Where do permission boundaries and SCPs sit?

**Do**
1. From scratch: a role trusted by EC2, a policy allowing read on exactly one S3 prefix, attached to an instance. SSM in and prove with the CLI that you can read that prefix and nothing else.
2. Deliberately over-scope then tighten: start at `s3:*` on `*`, narrow stepwise, testing after each narrowing until minimal. **This is the actual skill.**
3. Run IAM Access Analyzer / the policy simulator against your Jenkins policy. Note what it flags.
4. `docs/learn/03-iam.md` mapping every role in your repos to its trust, permissions, and *why*.

**~1.5 weeks.**

---

## 04 — `04-ecr-and-images`

**What's already in your repo:** [`modules/ecr/`](tf/modules/ecr/) — three repositories,
`scan_on_push`, a lifecycle policy expiring untagged images after 14 days, plus deployments
referencing those image URIs.

**Prove you understand it**
- Anatomy of `602367507570.dkr.ecr.us-east-1.amazonaws.com/frontend:latest` — name every part.
- Tag vs digest. Why is a tag mutable and a digest not? Why does that matter for `newTag: "latest"` in `apps/dev/kustomization.yaml`?
- What does `docker login` to ECR actually do? How does `aws ecr get-login-password` fit? Why does the EKS node role need `AmazonEC2ContainerRegistryReadOnly`?
- Read the lifecycle policy. What does it *actually* expire, and what does it *not*? (Flagged in your `ISSUES.md` — the description didn't match the behavior.)
- Image layers: change one line of app code — which layers rebuild? Why does Dockerfile instruction order matter so much?

**Do**
1. Write a multi-stage `Dockerfile` from scratch for a trivial app. Build it, get it small, run it as non-root.
2. Push it to an existing ECR repo by hand with the CLI. Pull it back. Inspect with `docker history` and `docker inspect`.
3. Push the same image under two tags; prove the digest is identical and layers were deduplicated.
4. Look at `scan_on_push` findings for a deliberately old base image (e.g. `node:14`). Read one CVE in full.
5. `docs/learn/04-images.md`, including a **corrected lifecycle policy** that does what the old description claimed.

**~1 week.**

---

## 05 — `05-jenkins-provisioning` 💰

**What's already in your repo:** [`modules/jenkins/main.tf`](tf/modules/jenkins/main.tf) — an
EC2 instance in a private subnet, no public IP, a security group with no ingress by default,
instance profile, SSM access, and a ~200-line `user_data` installing Java, Docker, Terraform,
kubectl, Helm, Checkov, Node, AWS CLI, and Jenkins.

**Prove you understand it**
- What is `user_data`, when does it run, and how many times? Where do its logs go? (Find them via SSM.)
- Why `set -euxo pipefail`? What does each letter do, and what would silently break without it?
- Why the `$${TERRAFORM_VERSION}` double-dollar? (Terraform interpolation vs shell expansion — a real gotcha.)
- The instance has no public IP. How does `user_data` download packages from the internet? Trace it.
- How does `aws ssm start-session` reach a box with **zero** inbound security-group rules? Explain the direction of the connection.
- What does the SSM agent specifically call that requires `AmazonSSMManagedInstanceCore`?
- `systemctl enable` vs `start` — what does each do, and what happens on reboot if you only do one?
- Why does Jenkins need to be in the `docker` group, and what's the security implication?

**Do**
1. Apply `shared-services`; get into Jenkins via SSM — both a shell and a port-forward to the UI. Retrieve the initial admin password. **This proves the access path in your README actually works.**
2. Read `/var/log/cloud-init-output.log` end to end. Find at least one thing that warned.
3. From scratch: an EC2 instance in a private subnet, `user_data` installing and starting nginx, an instance profile with SSM access, no ingress rules. Reach it via SSM port-forward. **This one exercise teaches half of AWS.**
4. Break it: remove the NAT route, re-apply, watch `user_data` fail. Diagnose it from the logs as a *network* problem, not a script problem.
5. `docs/learn/05-jenkins.md`.

**Destroy `shared-services` when done for the day. ~1.5 weeks.**

---

## 06 — `06-eks-cluster` 💰

**What's already in your repo:** [`modules/eks/`](tf/modules/eks/) — cluster, managed node
group, launch template with IMDSv2, cluster/node IAM roles, security group, access entries,
private endpoint always on, public endpoint per-environment.

**Prove you understand it**
- Control plane vs data plane. Which does AWS manage? Which do you pay per-hour for? Where do your pods actually run?
- What is the "EKS API endpoint"? What talks to it? Why do `staging`/`prod` set `endpoint_public_access = false`, and what does that mean for anything running `kubectl`?
- Why are nodes in *private-app* subnets while load balancers go in *public* subnets?
- `bootstrap_cluster_creator_admin_permissions = true` — who becomes cluster admin, and why does that mean staging/prod currently have exactly one admin identity?
- Access entries vs the old `aws-auth` ConfigMap. Why did AWS move? What does `AmazonEKSClusterAdminPolicy` grant?
- What does the launch template add that `aws_eks_node_group` can't do alone? What is IMDSv2, and what attack does `http_tokens = "required"` prevent?
- Managed node group vs self-managed vs Fargate vs Karpenter — one sentence each.
- What does `AmazonEKS_CNI_Policy` enable? How does the AWS VPC CNI give every pod a real VPC IP, and what per-instance-type pod limit does that cause?

**Do**
1. Apply `01-infra` for dev. `aws eks update-kubeconfig`, then `kubectl get nodes`, `kubectl get pods -A`. Look at what's running in `kube-system` *before* you deploy anything and identify each component.
2. From scratch in a scratch dir: a minimal EKS cluster + one node group, ~100 lines. No copying. This takes longer than you expect and teaches more than anything else here.
3. Break it: put the node group in a subnet with no NAT route. Watch nodes fail to join (they can't reach the API or ECR). Diagnose from `NotReady` to root cause.
4. `kubectl describe node` — read the whole thing. Allocatable vs capacity, conditions, taints, and why allocatable is less than the instance's actual RAM.
5. `docs/learn/06-eks.md`.

**~$0.10/hr control plane + nodes. Destroy nightly. ~2.5 weeks.**

---

## 07 — `07-kubernetes-by-hand` 💰

**What's in your repo:** [`gitops/apps/base/`](gitops/apps/base/) — three services, each a
Deployment + Service, plus per-environment namespaces.

**Why this step exists:** ArgoCD applies all this *for* you, which means you've never watched
Kubernetes do its job. Turn GitOps off and drive it by hand, once.

**Prove you understand it**
- Pod vs ReplicaSet vs Deployment — what does each layer add? What actually creates the pods?
- Step by step from `kubectl apply` to a running container: API server → etcd → scheduler → kubelet → container runtime. What does each do?
- Service types: ClusterIP, NodePort, LoadBalancer, ExternalName. Your `frontend` was LoadBalancer and the others ClusterIP — why, and what does that mean for reachability?
- How does a Service find its pods? (Labels/selectors → Endpoints/EndpointSlice.) Break the selector and watch it stop working.
- How does `order-service` resolve the name `frontend`? Explain CoreDNS and `frontend.development.svc.cluster.local`.
- Requests vs limits. What happens at the CPU limit vs the memory limit? (Throttling vs OOMKill — very different.)
- What does a namespace actually isolate — and crucially, what does it *not* isolate? (Network, by default.)

**Do**
1. **Suspend the ArgoCD root app's auto-sync** so it stops fighting you.
2. `kubectl apply` the three services by hand. Then use every one of: `get`, `describe`, `logs`, `logs --previous`, `exec -it`, `port-forward`, `top pod`.
3. **Break things deliberately and diagnose each from symptoms alone before looking:**
   - bad image name → `ImagePullBackOff`
   - a command that exits immediately → `CrashLoopBackOff`
   - requests larger than any node → `Pending` (read the scheduler event)
   - wrong Service selector → Service with no endpoints
   - memory limit below actual usage → `OOMKilled`
4. `kubectl exec` into `frontend` and `curl order-service` — prove cross-pod DNS works. Then curl the pod IP directly and compare.
5. Delete a pod; watch the ReplicaSet recreate it. Delete the ReplicaSet; watch the Deployment recreate *that*.
6. `kubectl rollout`: update an image, watch the rolling update, then `rollout undo`. Watch old and new pods coexist.
7. Re-enable ArgoCD sync and watch it reconcile away your manual changes — a valuable thing to see happen.
8. `docs/learn/07-kubernetes.md` with a table of **symptom → cause → diagnostic command**. You will use that table for the rest of your career.

**~2.5 weeks.** The most practically useful step in this file.

---

## 08 — `08-kustomize`

**What's in your repo:** [`gitops/apps/`](gitops/apps/) — a `base/` plus `dev`/`staging`/`prod`
overlays setting namespace and image tags.

**Prove you understand it**
- What problem does Kustomize solve that plain YAML doesn't? Why not just copy manifests per environment?
- Base vs overlay. What does `namespace:` in an overlay do to every resource in the base?
- Explain the `images:` transformer — what exactly does it rewrite, and how does it find the right container?
- Strategic merge patch vs JSON 6902 patch vs replace — when do you need each?
- Run `kustomize build apps/dev` and read the full output. Where did every line come from?
- Kustomize vs Helm: what does each do that the other can't? Why might a repo reasonably use both?
- What are `commonLabels`/`labels` for, and why do the `app.kubernetes.io/*` recommended labels matter?

**Do**
1. `kustomize build` all three overlays. Diff dev against prod and explain every difference.
2. Add a fourth overlay (`apps/qa/`) from scratch with its own namespace and tags. Verify with `kustomize build`.
3. Add a strategic-merge patch in one overlay only — e.g. `frontend` replicas to 4 in prod and nowhere else.
4. Add a `configMapGenerator` with a hash suffix; change a value and observe the generated name change (and therefore the pods roll — understand why that's a feature).
5. Introduce a deliberate error (reference a file that doesn't exist) and read the failure. **This is exactly the bug class that made your prod `app-secrets.yaml` silently never apply — it's silent by nature, so learn to recognize it.**
6. `docs/learn/08-kustomize.md`.

**~1 week.**

---

## 09 — `09-argocd-gitops` 💰

**What's in your repo:** ArgoCD installed via Helm in
[`02-services/main.tf`](tf/infrastructure/app-cluster/02-services/main.tf), a root Application
(App-of-Apps) pointing at [`gitops/bootstrap/projects/`](gitops/bootstrap/projects/), four
child Applications, `prune`/`selfHeal`, and the cascade-delete finalizer.

**Prove you understand it**
- What is GitOps, precisely? Push-based CI deployment vs pull-based reconciliation — why does the latter give you drift correction for free?
- Draw the App-of-Apps tree: root-app → 4 children → what each manages. Why this pattern instead of one Application per service?
- `syncPolicy.automated`: what does `prune: true` do? `selfHeal: true`? Construct a scenario where `prune` deletes something you didn't want deleted.
- **The finalizer, from first principles:** what is a Kubernetes finalizer? What does `deletionTimestamp` do? Who removes the finalizer? What happens if nobody ever does?
- Why did `finalizer` (singular) silently do nothing while `finalizers` (plural) works?
- Sync waves and hooks (`PreSync`/`Sync`/`PostSync`) — what problem do they solve?
- Health vs sync status — a resource can be Synced but Unhealthy. Give an example.
- Why is ArgoCD's Service `ClusterIP` now, and how do you reach the UI?

**Do**
1. Uninstall ArgoCD. **Install it yourself with `helm install`**, reading the values file. Create the root Application with `kubectl apply`. Understand every field.
2. Open the UI via port-forward, get the admin password, walk the resource tree, watch a sync live.
3. Test `selfHeal`: `kubectl edit` a Deployment's replicas and watch ArgoCD revert it. Then `kubectl delete` a Service and watch it come back.
4. Test `prune`: delete a manifest from git and watch the cluster resource disappear.
5. **Reproduce the finalizer bug deliberately.** Remove the finalizer, delete the root Application, confirm the child resources — including the `frontend` LoadBalancer — are orphaned. Put it back; confirm cascade deletion works. Get this in your hands, not just in theory.
6. Break a manifest (invalid YAML) and see how ArgoCD reports it — sync failure vs health failure.
7. `docs/learn/09-argocd.md` with the App-of-Apps diagram and the finalizer explained in your own words.

**~2 weeks.**

---

## 10 — `10-data-layer-secrets` 💰

**What's in your repo:** [`modules/database/`](tf/modules/database/) (ElastiCache Redis
running; RDS module present but `enable_rds = false`), [`modules/secrets/`](tf/modules/secrets/),
SSM parameters for endpoints, and the External Secrets Operator wiring in the gitops repo.

**Prove you understand it**
- Why do database resources go in *private-data* subnets with their own subnet group? What is a subnet group for?
- Read the Redis security group — it allows 6379 from the whole VPC CIDR. Why was that flagged as too broad in `ISSUES.md`, and what's the better pattern?
- Secrets Manager vs SSM Parameter Store: cost, rotation, size limits, encryption. When would you pick each? Your repo uses **both** — why?
- `recovery_window_in_days = 0` on the secret — what does that do, and why is it dangerous outside a learning environment?
- Trace the full path: Terraform creates ElastiCache → writes to Secrets Manager and SSM → ESO reads it → becomes a K8s Secret → a pod consumes it. Name every hop and what could break at each.
- Why is `manage_master_user_password = true` better than a password in tfvars?
- Read the RDS `lifecycle { precondition }` blocks. What do they prevent, and why is a precondition better than a comment?

**Do**
1. Confirm Redis is up. From a pod (`kubectl run -it --rm redis-cli --image=redis -- sh`), connect and `SET`/`GET` a key. **Prove the data layer is actually reachable from a workload** — most people never check.
2. Read the secret in Secrets Manager and the SSM parameters in the console; match them against what Terraform wrote.
3. Confirm ESO works: `kubectl get externalsecret -A`, `describe` one, then `kubectl get secret app-secrets -o yaml` and decode it. **If it's failing, diagnosing why is the more valuable outcome.**
4. From scratch: ElastiCache Redis with a subnet group and a security group allowing access *only* from a specific source security group — not the whole VPC.
5. Change the value in Secrets Manager and watch ESO refresh the K8s Secret (mind `refreshInterval: 1h`).
6. `docs/learn/10-data-secrets.md` with the full secret-flow diagram.

**~1.5 weeks.**

---

## 11 — `11-irsa-oidc` 💰

**What's in your repo:** the OIDC provider and generic `irsa_roles` map in
[`modules/eks/main.tf`](tf/modules/eks/main.tf), with roles for `external_secrets` and
`aws_lb_controller`, plus ServiceAccount annotations in `02-services`.

**Why this gets its own step:** IRSA is the hardest concept in your repos and the most
cargo-culted. It's also the correct answer to "how does my pod get AWS permissions," which
comes up constantly. Understand it properly once.

**Prove you understand it**
- Three ways a pod could get AWS credentials — node instance profile, static keys in a Secret, IRSA. Why is IRSA correct and the others bad?
- What is OIDC? What is a JWT, and what are its three parts? **Decode your cluster's projected SA token** (`/var/run/secrets/eks.amazonaws.com/serviceaccount/token`) at jwt.io and read the claims.
- Walk the **full handshake**: pod starts → kubelet projects a signed SA token → SDK reads `AWS_WEB_IDENTITY_TOKEN_FILE` → calls `sts:AssumeRoleWithWebIdentity` → STS validates the signature against the cluster's OIDC issuer → temporary credentials. Name what could break at each step.
- Why does the trust policy condition on **both** `:sub` (`system:serviceaccount:<ns>:<name>`) and `:aud` (`sts.amazonaws.com`)? What attack does each prevent?
- Why must `aws_iam_openid_connect_provider` exist in IAM at all — what does AWS need it for?
- What is the `thumbprint_list`, and why does the config use the `tls_certificate` data source to compute it?
- Why does the `eks.amazonaws.com/role-arn` annotation go on the **ServiceAccount** rather than the pod or Deployment?
- Why couldn't the LB controller's IAM policy be scoped tighter (some statements are `Resource: "*"`)? Read it and form a view.

**Do**
1. `kubectl describe sa external-secrets-sa -n kube-system` — find the annotation. Then `kubectl exec` into that pod and print `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE`.
2. From inside that pod, run `aws sts get-caller-identity`. **See the assumed role in the output** — this is the moment IRSA becomes real.
3. Create a brand-new IRSA role from scratch for a test ServiceAccount scoped to read one S3 prefix. Deploy a pod using that SA and prove from inside it that you can read that prefix and nothing else.
4. Break it three ways and observe each distinct failure: wrong namespace in `:sub`, wrong SA name in `:sub`, annotation removed from the SA.
5. `docs/learn/11-irsa.md` with the handshake as a Mermaid sequence diagram.

**~2 weeks.**

---

## 12 — `12-pipeline-and-the-destroy-bug` 💰

**What's in your repo:** the [`Jenkinsfile`](tf/Jenkinsfile) — parameterized declarative
pipeline, `fmt` check, two-layer init/plan/apply, manual approval gates, and a destroy path
tearing down Layer 2 before Layer 1.

**Prove you understand it**
- Declarative vs scripted Jenkins pipelines. What are `stages`, `steps`, `when`, `post`, `input`, `parameters`?
- Why does the destroy path plan Layer 2 *before* the approval gate while Layer 1 is planned earlier? Trace the exact execution order for both `apply` and `destroy`.
- Why does `terraform plan -destroy -out=...` then `terraform apply <plan>` work as a destroy? What is a saved plan file, and why does the pipeline delete them in `post`?
- Why is Layer 2's init/plan skipped on a fresh `apply` (`when { expression { params.ACTION == 'destroy' } }`)? What breaks without that guard?
- Why can't the two layers be one root module? (The bootstrapping problem: Layer 2's `helm`/`kubernetes` providers need a cluster that doesn't exist at plan time.)
- Where does the pipeline get AWS credentials? Why is that the right design?
- Checkov runs but doesn't fail the build. Why is that nearly useless?

**Do**
1. Run the pipeline for real, both `apply` and `destroy`, reading every stage's console output. Don't skim.
2. **Re-derive the original destroy bug from first principles, without re-reading the earlier analysis.** Given: Layer 2 destroys before Layer 1; `frontend` is `type: LoadBalancer`; ArgoCD's Application had no finalizer. Explain precisely why destroy failed at NAT gateway and subnet deletion. Draw the chain: K8s Service → AWS ELB → ENIs → subnet → `DependencyViolation`.
3. Now explain why the *ordering was never the bug*, and why the fix belonged in the ArgoCD Application rather than the Jenkinsfile. **If you can teach this cleanly, this whole file has worked.**
4. Reproduce it: remove the finalizer, apply, then destroy. Watch it fail. Read the exact AWS error. Clean up the orphaned ELB by hand, then destroy successfully.
5. Add one improvement of your own: make Checkov fail the build on high-severity findings, then fix what it flags.
6. `docs/learn/12-pipeline.md` with the destroy dependency chain diagram.

**~1.5 weeks.**

---

# Exit test — do this before opening roadmap 02

In one sitting:

1. **Destroy everything.** Both layers, shared-services, all of it.
2. **Rebuild the entire platform from an empty AWS account**, using only your own
   `docs/learn/` notes and the repo. **No AI assistance, no tutorials.**
3. Time it. Write down every place you got stuck.
4. Then explain, out loud and unaided in under 15 minutes:
   - what the three Terraform layers do and why they're split
   - how a request reaches a pod, hop by hop
   - how a pod gets AWS permissions
   - why `terraform destroy` used to fail

If you can do that, the repos are genuinely yours and everything in roadmap 02 is additive.

If you can't, the specific place you stalled tells you exactly which step to redo — and
redoing one step now is far cheaper than carrying the gap through 43 more.

---

## A note on what this is worth

"I inherited an AI-built platform, then rebuilt it from scratch myself to prove I understood
it" is a **better** interview story than "I followed a tutorial series." It's also true, and
it demonstrates exactly the judgment that distinguishes engineers who can be trusted with
production from ones who can only be trusted with a happy path.

Finishing this file is a real milestone. Then open `LEARNING-ROADMAP.md`.
