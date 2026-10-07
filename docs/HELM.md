# Our own Helm chart: `charts/microservice`

Roadmap step 06. Until now every chart in this repo came from someone else
(Prometheus, Tempo, Karpenter, ...), and our three services were plain YAML
plus Kustomize patches. This step writes **our own chart** and deploys
**order-service** with it in every environment. **frontend** and
**user-service** stay on Kustomize, so the two approaches sit side by side.

```
charts/
├── common/                       a library chart: renders nothing itself; shared
│   └── templates/_names.tpl,     helpers for names and the standard labels
│       _labels.tpl                (app.kubernetes.io/name, version, part-of, ...)
└── microservice/                 the application chart
    ├── Chart.yaml                name, version 0.1.0, depends on common (file://../common)
    ├── Chart.lock                the resolved dependency (CI and ArgoCD rebuild charts/ from it)
    ├── values.yaml               every setting with its default (what order-service needs)
    ├── values.schema.json        what values may contain: a typo is an error, not ignored
    ├── templates/                Deployment, Service, ServiceAccount, HPA, PDB, VPA,
    │                             ServiceMonitor, each switchable in values
    └── tests/                    helm-unittest suites (17 tests)

apps/<env>/order-service.values.yaml   only what differs in that environment:
                                       image tag, environment name, payload logging
bootstrap/projects/order-service-<env>.yaml   the ArgoCD Application that deploys it
bootstrap/envs/local/order-service.yaml        (the lab's)
```

The chart renders the same order-service the Kustomize files did: the same
probes, resources, security settings, shutdown, spreading, HPA, PDB, VPA and
ServiceMonitor. The Deployment's selector is unchanged (`app: order-service`),
so ArgoCD takes over the running Deployment instead of replacing it.

## Kustomize or Helm?

| | Kustomize (frontend, user-service) | Helm (order-service) |
|---|---|---|
| How a variation is made | Patch the base YAML per environment | Fill in values in one template |
| Where the settings live | Spread over base files, components, overlay patches | `values.yaml` (defaults) + one values file per environment |
| Checking the settings | Only the rendered YAML's schema | `values.schema.json`: wrong keys, a mistyped tag or environment fail at once |
| Reuse | Copy the base per service | One chart for any number of services |
| Versioning | The Git commit | Chart version (0.1.0), published to ECR, installable anywhere |
| Logic | None, by design | Conditionals and loops: powerful, and easy to overdo |
| Unit tests | No | helm-unittest |

Kustomize is simpler while there are few, different services; a chart pays
off once several services share the same shape (as these do) or when others
install your software. The two can be combined: ArgoCD can render a chart
and patch the result with Kustomize.

## Everyday tasks

**Change a setting for one environment**: edit `apps/<env>/order-service.values.yaml`.
The settings you can use, with their defaults, are in
`charts/microservice/values.yaml`.

**Deploy a new image**: run the gitops Jenkins job with `SERVICE_NAME=order-service`.
For order-service it edits `image.tag` in the values file instead of a
`kustomize edit set image`, and opens a pull request as for the other
services. The tag must be a 40-character commit SHA (the schema enforces it).

**Change the chart**: edit `charts/microservice`, then
1. bump `version` in `Chart.yaml` (0.1.0 → 0.2.0; patch for fixes, minor for
   new values, major when existing values change meaning),
2. add or update a test in `charts/microservice/tests`,
3. run `./scripts/validate.sh`. It builds the dependency, lints the chart
   with every environment's values, runs the unit tests and renders every
   environment.

After the merge, Jenkins publishes the new version to ECR (`scripts/publish-chart.sh`).
Republishing a version with different contents fails: ECR tags are immutable,
so a version always means the same chart.

**Roll back**: `git revert` the change. ArgoCD deploys the chart from Git,
so the cluster follows. ArgoCD renders the chart itself (`helm template`):
there is no Helm release in the cloud clusters, so `helm rollback` is for
the lab and for installs from ECR.

**Install the published chart from ECR** (anywhere with ECR access):

```bash
helm install order-service oci://602367507570.dkr.ecr.us-east-1.amazonaws.com/charts/microservice \
  --version 0.1.0 -n development -f apps/dev/order-service.values.yaml
helm history order-service -n development
helm rollback order-service 1 -n development
```

## Checks

```bash
helm dependency build charts/microservice
helm lint charts/microservice -f apps/dev/order-service.values.yaml
helm unittest charts/microservice               # plugin: helm-unittest v1.0.3
helm template order-service charts/microservice -n development -f apps/local/order-service.values.yaml
```

All of these run in `./scripts/validate.sh` (and so in Jenkins).

## Switching an existing environment over

- **Cloud (ArgoCD):** on the first sync, the `<env>-env` app drops
  order-service from its objects and the new `order-service` app takes them
  over (the old HPA `order-hpa` and ServiceMonitor `order-service-monitor`
  are pruned; the chart names them `order-service`). Depending on which app
  syncs first, order-service may restart once.
- **Lab:** `scripts/sync-local-stack.rb` installs the chart with
  `helm upgrade --install --take-ownership` (Helm 3.17 or later), which adopts
  the objects Kustomize created. Remove the two that the chart names
  differently once, so two HPAs don't fight over one Deployment:
  ```bash
  kubectl delete hpa order-hpa servicemonitor order-service-monitor -n development
  ```

## Exercise

Move user-service to the same chart. Its values file needs a different
`image.repository`, `contextPath: /api` (and the matching ALB health-check
annotation) and its `ORDER_SERVICE_URL`. Once all three services use it, the
`apps/base` copies and the two Kustomize components can go.
