# Progressive delivery: releases that check themselves

Roadmap step 20. A Deployment's rolling update replaces pods as soon as the new ones are
*ready*, and ready only means the health check answers. A version that answers its health
check and then fails a third of its requests, or takes two seconds for each, is rolled out
to everyone just the same. **Argo Rollouts** releases a new version step by step, measures
how it actually behaves, and rolls it back by itself when it misbehaves.

```
                        Kong ──► waypoint ── VirtualService order-service, route "primary"
                                     │          weights set by Argo Rollouts
                     ┌───────────────┴──────────────┐
                 90% ▼                          10% ▼
       Service order-service              Service order-service-canary
       (stable pods, old version)         (canary pods, new version)
                                                    │ their own request metrics
                                                    ▼
                              AnalysisRun: errors ≤ 5%, ≥ 90% within 500 ms ── fail ──► abort:
                                                    │ pass                              all traffic
                                                    ▼                                   back to stable
                                        25%, 50%, then 100%: the new version is stable
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Argo Rollouts 1.10 | `addons/applications/argo-rollouts.yaml`, `addons/values/*/argo-rollouts.yaml` | The controller (two in the cloud), its CRDs, its metrics; permissions for Istio only. Every environment |
| order-service, a canary | `charts/microservice` (`rollout:` values, 0.9.0), `apps/<env>/order-service.values.yaml` | A Rollout instead of a Deployment; Service `order-service-canary`; the analysis (`analysistemplate.yaml`) |
| Traffic weights | `apps/base/mesh.yaml`, VirtualService `order-service` | Route `primary` lists the stable and the canary Service; Argo Rollouts sets their weights |
| frontend, blue/green | `apps/base/frontend/rollout.yaml`, Service `frontend-preview` | The next version waits beside the current one until someone promotes it |
| ArgoCD | `bootstrap/projects/*.yaml`, `bootstrap/envs/local/*.yaml` | Ignores the weights Argo Rollouts moves; removes the old Deployments only once the Rollouts are healthy |
| Alerts | `observability/base/rollout-alerts.yaml`, `service-alerts.yaml` | `RolloutFailed`, `ArgoRolloutsControllerUnavailable`; `ServiceUnavailable` reads Rollouts too |
| A bad version on demand | app `order-service`, `app.fault.error-rate` | Fails a share of the API's requests, to watch a canary being rolled back |

## Design choices, and why

**Two strategies, for two kinds of service.** order-service is released as a **canary**:
a small share of the requests goes to the new version, which is measured while the share
grows. That takes request metrics from the new version alone, which order-service has.
frontend is released **blue/green**: the whole new version starts beside the current one,
reachable only through a preview Service, and takes over every user at once when a person
promotes it. A user interface is something people want to look at before everyone gets it,
and the frontend (static files behind nginx) has no request metrics of its own to measure a
canary with. The roadmap suggested the opposite pairing; this one fits what each service is.

**The mesh moves the traffic, not the pod count.** Without a traffic router, a canary's
"10%" is one pod in ten, and with two pods the first step is already half the traffic.
With one, the weights are shares of the requests, whatever the pod count. Kong could
weight its own routes, but only the requests coming from outside: user-service's calls to
order-service would bypass the split. The mesh's waypoint sees every request to the
Service, from any caller, so Argo Rollouts sets the weights there, in the VirtualService
that already holds order-service's retries and timeouts (step 18).

Istio calls VirtualServices on waypoints **alpha** in ambient mode; the **beta** way is an
HTTPRoute attached to the Service, which Istio says not to mix with a VirtualService on the
same Service. Argo Rollouts reaches HTTPRoutes only through its Gateway API plugin, a
separate program it downloads at start-up, one build per processor type: the lab may run on
an ARM laptop and the cloud on Intel nodes, so one pinned download can't serve both. The
built-in Istio router needs nothing extra and uses the VirtualService already there. When
the plugin ships in the controller's image, or Istio's VirtualService support leaves alpha,
revisit this.

**Measured on its own requests.** Each pod carries its version's pod template hash as a
label; the ServiceMonitor copies it onto the metrics; the analysis asks Prometheus about the
new hash only. So the old version's good numbers can't hide the new version's bad ones, and
the mesh's metrics aren't needed. Two measures, the same as the SLOs: **errors** (at most 5%
of its answers are 5xx; the SLO allows 0.5% over a month, but a few minutes of a canary is a
small sample) and **latency** (at least 90% answered within 500 ms, the SLO's threshold).
Every minute from the first pause to the end; a second failure of either rolls the release
back. A canary whose pods don't become ready within 10 minutes is rolled back too
(`progressDeadlineAbort`).

**When there's nothing to measure.** With no requests, a measurement is 0/0. In production,
where traffic never stops, that means the metrics are broken, and passing would let every
release through unexamined; there (`withoutRequests: wait`, the chart's default) it counts
as *inconclusive* and the release pauses for a person. The lab, dev and staging see little
or no traffic, so there it passes (`withoutRequests: pass`). Exercises drive traffic on
purpose.

**Manual promotion for the frontend.** `autoPromotionEnabled: false` in every
environment: after each new image, someone looks at the preview and runs `kubectl argo
rollouts promote frontend`. In dev, where Jenkins bumps the image on every merge, that is a
real step in the process, and the point of blue/green. Only one preview pod runs
(`previewReplicaCount: 1`); at promotion it grows to the full count before taking over, and
the old version stays 30 seconds more for requests in flight.

**ArgoCD and Argo Rollouts side by side.** ArgoCD makes the cluster match Git; Argo Rollouts
changes three things on purpose during a release. The Services' selectors (it adds the pod
template hash) ArgoCD doesn't notice, because it compares only fields Git sets. The
VirtualService's weights it would notice and reset halfway through a canary, so each
environment's application ignores them (`ignoreDifferences`, with
`RespectIgnoreDifferences` so a sync leaves them alone too). And turning a Deployment into a
Rollout means ArgoCD deletes the Deployment: with `PruneLast` it does that only after the
Rollout is healthy, so the old pods keep serving until the new ones are ready.

**No dashboard in the cluster.** Argo Rollouts' web dashboard has no login, and anyone who
reaches it can promote or abort any release. `kubectl argo rollouts dashboard` serves the same
page on your own machine, with your own Kubernetes permissions.

**What it changed elsewhere.** The mesh's caller policies cover the new Services
(`order-service-canary`, `frontend-preview`) with the same rules as the main ones. The
NetworkPolicies needed nothing: the pods keep their labels. The autoscalers (HPA, KEDA, VPA)
point at the Rollouts. `ServiceUnavailable` reads Argo Rollouts' metrics for the two
services, since a Rollout has no Deployment for kube-state-metrics to see. The lab scripts
release a rebuilt image as a new revision instead of restarting a Deployment, and the alert
drill scales either kind.

**Not done here.** user-service and notification-service stay Deployments: user-service
holds the sign-in keys and is a natural second canary once order-service's has run a while;
notification-service is a Kafka consumer, whose new version would need its share of
*events*, not requests. Notifications from Argo Rollouts itself (the alerts cover failures);
experiments and header-based routing (`setHeaderRoute`, a tester's requests to the canary).

## Where it runs

Every environment. In the lab the controller takes about 128 MiB; during a release one more
order-service pod (512 MiB) or frontend pod runs beside the others.

## Try it in the lab

Install the kubectl plugin (`brew install argoproj/tap/kubectl-argo-rollouts`, or the
`kubectl-argo-rollouts` binary of release v1.10.2 from GitHub), then
`scripts/sync-local-stack.rb`. The first time, the lab's sync doesn't remove the old
frontend Deployment the way ArgoCD would; once `kubectl argo rollouts get rollout frontend
-n development` shows Healthy, `kubectl delete deployment frontend -n development`.
order-service is replaced by Helm in one go, so it restarts for about a minute.

1. **Look around.** `kubectl argo rollouts list rollouts -n development`, and
   `kubectl argo rollouts dashboard` (http://localhost:3100).
2. **A good release.** In one terminal, traffic through the front door:

   ```bash
   kubectl run load -n default --rm -it --image=busybox:1.37 --restart=Never -- \
     sh -c 'while true; do wget -q -O /dev/null http://kong-gateway-proxy.kong/api/orders/status; sleep 0.2; done'
   ```

   In another, `kubectl argo rollouts get rollout order-service -n development --watch`.
   Make a change: add `- {name: RELEASE_NOTE, value: "first canary"}` under `extraEnv` in
   `apps/local/order-service.values.yaml` and run the sync. Watch the weights go 20, 50, 100
   (`kubectl get virtualservice order-service -n development -o yaml` shows them) and the
   analysis runs pass.
3. **A bad release.** Add `- {name: APP_FAULT_ERROR_RATE, value: "0.5"}` instead and sync,
   with the traffic still running. Half of the canary's requests fail; within two
   measurements the analysis fails, the rollout aborts, and all traffic is back on the old
   version, without anyone touching anything. `RolloutFailed` fires a minute later.
   `kubectl describe analysisrun -n development` shows the error rate it measured. Remove
   the line and sync: the next release starts over.
4. **Blue/green.** Change something visible in `app/frontend`, then
   `scripts/update-and-redeploy-podman.sh frontend`. The new version waits:
   `kubectl port-forward -n development svc/frontend-preview 8080:80` shows it on
   localhost:8080 while localhost (through Kong) still shows the old one. Then
   `kubectl argo rollouts promote frontend -n development`, or `abort` to throw it away.

## Deploying to dev

Merging gitops installs Argo Rollouts, then turns frontend and order-service into Rollouts;
ArgoCD keeps their Deployments until the Rollouts are healthy, then removes them
(`kubectl get deploy,rollout -n development` while it happens). Merging the app repo builds
an order-service image with the fault switch (off). From then on, each new order-service
image is released as a canary (about ten minutes), and each new frontend image waits in
preview for `kubectl argo rollouts promote frontend -n development`. Nothing in Terraform
changes.
