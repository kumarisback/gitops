# Runbooks

One section per alert defined in `observability/base`. Every alert's
`runbook_url` points at its section here. Each section says what the alert
means, how to confirm it, and what to do.

Grafana is at `kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring`
(local lab) or the environment's Grafana URL. The two dashboards referenced
below are **Microservices** and **Service Level Objectives**.

Severity decides where an alert goes (see Alertmanager in
`addons/values/cloud/kube-prometheus-stack.yaml`):

| Severity | Goes to | Expectation |
|---|---|---|
| `critical` | PagerDuty (and Slack) | Someone acts now, any hour. |
| `warning` | Slack | Someone looks within the working day; open a ticket if it isn't trivially fixed. |

---

## Service availability

### ServiceUnavailable

**Meaning:** no pod of the Deployment has been ready for 2 minutes, so every
request to the service fails. Users are affected now. While it fires,
Alertmanager holds back that service's `ServiceDown`, `ServiceMetricsMissing`
and SLO alerts, which would only repeat it.

**Check:**

```bash
kubectl get deploy,pods -n <namespace> -l app=<service>
kubectl describe deploy <service> -n <namespace>      # conditions; replicas 0 on purpose?
kubectl get events -n <namespace> --sort-by=.lastTimestamp | tail -20
```

Common causes, roughly in order: a bad rollout (`CrashLoopBackOff`, failing
readiness), an image that can't be pulled (`ImagePullBackOff`: the pinned tag
isn't in ECR), the namespace quota (`exceeded quota` on the ReplicaSet), no
node with room (`Pending`; check Karpenter), or someone scaled it to 0.

**Act:** roll back a bad release first (`git revert` the image-tag commit and
let ArgoCD sync). For the other causes, fix that cause. Scaled to 0 on purpose: silence
the alert for the maintenance window.

### ServiceDown

**Meaning:** Prometheus has failed to scrape one backend pod's
`/actuator/prometheus` for 2 minutes. The pod is down, not ready, restarting,
or the actuator endpoint is failing.

**Check:**

```bash
kubectl get pods -n <namespace> -l app=<service>
kubectl describe pod -n <namespace> <pod>          # events: OOMKilled, probes, image pulls
kubectl logs -n <namespace> <pod> --previous        # if it restarted
```

In Grafana, Explore → Loki: `{namespace="<namespace>", container="<service>", log_type="server"} | json | level="ERROR"`.

**Act:** if a rollout caused it, roll back (`git revert` the image-tag commit
and let ArgoCD sync). If MongoDB is unreachable, readiness fails by design
(`readinessState,mongo`); fix connectivity or the `app-secrets` Secret.

### ServiceMetricsMissing

**Meaning:** Prometheus has had **no** scrape target for the service for 10
minutes, not even a failing one. Usually a configuration problem rather than
an outage: the Service is gone, lost its `app` label, or the ServiceMonitor
no longer matches it.

**Check:**

```bash
kubectl get svc -n <namespace> <service> --show-labels      # needs app=<service>
kubectl get servicemonitor -n <namespace>
kubectl get endpoints -n <namespace> <service>               # empty = no ready pods
```

Prometheus → Status → Targets should list `serviceMonitor/<namespace>/<service>-monitor/0`.

**Act:** restore the label or ServiceMonitor from Git (`apps/base/<service>/`).
Until this is fixed, the service's SLO alerts can't fire.

---

## SLOs

Objectives (30-day rolling): **availability**, 99.5% of requests without a
5xx (budget 0.5%), and **latency**, 99% of requests within 500ms (budget 1%).
Actuator endpoints are excluded. Definitions and burn-rate thresholds are in
`observability/base/slo-rules.yaml`. The *Service Level Objectives*
dashboard shows the budget left and the burn rates.

A **burn rate** of 1x spends the 30-day budget in exactly 30 days. The fast
alerts page at 14.4x over an hour (2% of the budget gone) or 6x over six
hours (5% gone). The slow alerts open a ticket at 3x over a day or 1x over
three days.

### SLOAvailabilityBudgetBurnFast

**Meaning:** the service is returning 5xx to enough requests that, if it
continues, the whole month's error budget is gone in under two days.
Customers are seeing errors now.

**Check:**

1. Microservices dashboard → *API 5xx Rate* for which service and status.
2. Which endpoint: in Prometheus,
   `sum by (uri, status) (rate(http_server_requests_seconds_count{job="<service>", status=~"5.."}[5m]))`.
3. Why: Explore → Loki
   `{namespace="<namespace>", log_type="api"} | json | http_response_status_code >= 500`
   (in staging and production the line includes the request payload),
   then click the line's **trace_id** to open the trace in Tempo and find the
   failing span (Mongo, the downstream call to order-service, ...).
4. Did something change? `git log` on `apps/<env>/` and the ArgoCD history.

**Act:** roll back a bad release first, investigate second. If a dependency
(MongoDB, order-service) is failing, fix or fail over that. The alert clears a
few minutes after the error rate drops.

### SLOAvailabilityBudgetBurnSlow

**Meaning:** a low but steady 5xx rate over a day or more. Nobody needs to be
woken up, but the service will miss its monthly objective if nothing changes.

**Check:** the same queries as the fast alert, over 1-3 days. Look for one
endpoint or one error type (`| json | level="ERROR" | line_format "{{.logger}} {{.message}}"`).

**Act:** open a ticket with the endpoint, the error and an example trace.

### SLOLatencyBudgetBurnFast

**Meaning:** many requests are taking longer than 500ms; at this rate the
month's latency budget is gone in under two days.

**Check:**

1. Microservices dashboard → *API P95 Latency*, and *Pod CPU* for throttling
   against the CPU limit.
2. Slow endpoints: Explore → Loki
   `{namespace="<namespace>", log_type="api"} | json | duration_ms > 500`,
   or the *API calls* panel on the Microservices dashboard; `http_route` says
   which endpoint.
3. Where the time goes: open a slow request's trace in Tempo, or search
   TraceQL `{ resource.service.name = "<service>" && duration > 500ms }`.

**Act:** scale out if CPU-bound (raise the HPA's `maxReplicas` or the CPU
limit), roll back a slow release, or fix the slow dependency the trace shows.

### SLOLatencyBudgetBurnSlow

**Meaning:** a steady share of slow requests over a day or more.

**Check / Act:** as for the fast alert, over 1-3 days; open a ticket.

---

## Observability pipeline

These fire when logs or traces stop reaching Loki or Tempo. They are
`warning`: nothing is broken for users, but the next incident will be
investigated blind. The path is drawn in `docs/observability-pipeline.html`.

### LogShipperMissing

**Meaning:** Prometheus has no `loki_write_*` metrics at all, so Alloy isn't
running or isn't being scraped.

**Check:** `kubectl get pods -n monitoring -l app.kubernetes.io/name=alloy`;
`kubectl logs -n monitoring deploy/alloy-logs`; ArgoCD app `alloy-logs`.

**Act:** fix the Deployment (often a config error after a change; run
`./scripts/validate.sh`, which runs `alloy validate`). If the
ServiceMonitor is missing, check `serviceMonitor.enabled` in
`addons/values/common/alloy.yaml`.

### LogShipperStalled

**Meaning:** Alloy is up but has sent nothing for 20 minutes.

**Check:** Alloy's logs for `permission denied` on `pods/log` (RBAC) or
connection errors to `loki.monitoring:3100`. In the Alloy UI
(`kubectl port-forward deploy/alloy-logs 12345 -n monitoring`, then
http://localhost:12345) check that `loki.source.kubernetes` has targets.

**Act:** restore RBAC or Loki connectivity; restart Alloy once fixed.

### LogShipperDroppingLines

**Meaning:** Alloy retried and then gave up on log lines. They are lost.

**Check:** look for `LokiRejectingLines` or `LokiPushErrors` at the same
time; Alloy's logs show the HTTP status Loki returned.

**Act:** fix Loki first (below). For `429` raise Loki's
`limits_config.ingestion_rate_mb` / `per_stream_rate_limit` in
`addons/values/*/loki.yaml`.

### LokiRejectingLines

**Meaning:** Loki accepted the push but discarded lines, grouped by `reason`:
`rate_limited`, `per_stream_rate_limit`, `stream_limit`, `greater_than_max_sample_age`,
`line_too_long`.

Limits are per tenant: `apps` (application namespaces) and `platform`
(everything else); the cloud tier gives `platform` half of `apps`'
ingestion rate and 7 days' retention instead of 30.

**Act:** raise the matching limit in `addons/values/*/loki.yaml` (per tenant
under `loki.runtimeConfig.overrides`), or find the noisy stream (`topk(5, sum by (namespace, container) (rate({namespace=~".+"}[5m])))`
in Explore → Loki) and quiet it at the source.

### LokiPushErrors

**Meaning:** Loki is returning 5xx to pushes.

**Check:** `kubectl logs -n monitoring loki-0`; PVC or S3 errors; memory
(`kubectl top pod -n monitoring`).

**Act:** fix storage or raise Loki's memory limit; Alloy retries meanwhile.

### TraceCollectorDroppingSpans

**Meaning:** the OTel Collector failed to export spans to Tempo, or refused
incoming spans because `memory_limiter` hit its limit.

**Check:** `kubectl logs -n monitoring deploy/otel-collector-opentelemetry-collector`;
`otelcol_receiver_refused_spans` vs `otelcol_exporter_send_failed_spans` in
Prometheus tells you which side.

**Act:** export failures: fix Tempo (below). Refusals: raise the collector's
memory limit and `memory_limiter.limit_mib` together in
`addons/values/common/otel-collector.yaml`, or add replicas.

### TraceCollectorQueueFilling

**Meaning:** the collector's queue to Tempo is over 80% full; Tempo is slow or
unreachable, and spans are dropped when it fills.

**Act:** as for `TempoDiscardingSpans` and Tempo's health.

### TracePipelineStalled

**Meaning:** spans arrive at the collector, none leave.

**Check:** collector logs for exporter errors; that
`tempo.monitoring:4317` resolves and Tempo is ready.

**Act:** fix the exporter endpoint or Tempo; run `./scripts/validate.sh`
after any collector config change (it runs `otelcol-contrib validate`).

### TempoDiscardingSpans

**Meaning:** Tempo dropped spans, grouped by `reason` (`rate_limited`,
`trace_too_large`, `live_traces_exceeded`).

**Act:** raise Tempo's ingestion limits (`overrides` in
`addons/values/*/tempo.yaml`), or find the service producing huge traces in
TraceQL (`{ } | count() > 1000`).

### TailSamplerOverloaded

**Meaning:** the sampler holds each trace for `decision_wait` (10s) before
deciding; more traces arrived than `num_traces` can hold, so some were
dropped without a decision, errors included.

**Act:** raise `num_traces` (and memory) in
`addons/values/common/otel-collector-sampler.yaml`, or add sampler
replicas; check `otelcol_processor_tail_sampling_sampling_traces_on_memory`.

### TraceGatewayHasNoSamplers

**Meaning:** the gateway's `loadbalancing` exporter resolves
`otel-collector-sampler.monitoring.svc.cluster.local` to no pods.

**Check:** `kubectl get pods,endpoints -n monitoring -l app.kubernetes.io/instance=otel-collector-sampler`;
the ArgoCD app `otel-collector-sampler`.

**Act:** get the sampler running; the gateway re-resolves DNS on its own.
