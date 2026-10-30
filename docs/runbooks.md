# Runbooks

One section per alert defined in `observability/base`. Every alert's
`runbook_url` points at its section here. Each section says what the alert
means, how to confirm it, and what to do.

Grafana is at `kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring`
(local lab) or the environment's Grafana URL. The dashboards referenced
below are **Is everything OK?** (start there), **Microservices** and
**Service Level Objectives**.

Severity decides where an alert goes (see Alertmanager in
`addons/values/cloud/kube-prometheus-stack.yaml`):

| Severity | Goes to | Expectation |
|---|---|---|
| `critical` | PagerDuty (and Slack) | Someone acts now, any hour. |
| `warning` | Slack | Someone looks within the working day; open a ticket if it isn't trivially fixed. |

---

## Service availability

### ServiceUnavailable

**Meaning:** no pod of the Deployment has been ready for 2 minutes although
some are wanted, so every request to the service fails (for notification-service:
its Kafka backlog grows). Users are affected now. A Deployment scaled to zero on
purpose (KEDA, or by hand) doesn't fire it. While it fires,
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
node with room (`Pending`; check Karpenter). For a service KEDA scales from
zero, the same causes show up as the first pod after a quiet period never
becoming ready.

**Act:** roll back a bad release first (`git revert` the image-tag commit and
let ArgoCD sync). For the other causes, fix that cause.

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

**Act:** restore the label or ServiceMonitor from Git: `apps/base/<service>/` for
frontend and user-service, `charts/microservice` (and `apps/<env>/order-service.values.yaml`)
for order-service.
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

## Synthetic checks

The blackbox exporter makes the same requests a user would, every 30
seconds, whether or not anyone is using the app (`docs/SYNTHETIC-MONITORING.md`).
Each probe has the labels `service`, `check` and `via`: `via="service"`
goes straight to the Service, `via="ingress"` through the lab's Traefik.
The **Is everything OK?** dashboard shows every check.

Reproduce a check by hand from inside the cluster:

```bash
kubectl port-forward svc/blackbox-exporter 9115 -n monitoring
curl -s 'localhost:9115/probe?module=http_signin_rejected&target=http://user-service.<namespace>.svc.cluster.local/api/auth/signin&debug=true'
```

`debug=true` prints each step of the probe: DNS, connect, the status code,
the body match, and the reason it failed.

### EndpointDown

**Meaning:** a check has failed for 2 minutes: no answer, a wrong status
code, a body without the expected content, or a TLS error. Users doing
the same thing get the same result.

**Check:** which `check` and `via`:

- `via="service"` failing too: the service itself. If `ServiceUnavailable`
  fires for it, start there. Otherwise look at the probe's debug output
  and the service's logs (`ServiceDown` above has the queries).
- only `via="ingress"` failing: the routing. `kubectl get ingress app-ingress -n development -o yaml`,
  Traefik's logs (`kubectl logs -n traefik deploy/traefik`).
- `check="signin"` with status 500: user-service couldn't check the
  credentials, usually MongoDB. With **200**: sign-in accepted a random
  password (the probe makes a new one each time its pod starts), so
  authentication itself is broken. Treat it as a security incident: roll
  back the last user-service release.
- `check="status"` with status 200: order-service answered without
  `"status":"ONLINE"`.

**Act:** roll back a bad release (`git revert` the image-tag commit). For
routing, revert the Ingress or Traefik change.

### EndpointSlow

**Meaning:** a check still succeeds but has averaged over 1s for 15
minutes.

**Check:** the debug output splits the time into DNS, connect and the
response (`probe_http_duration_seconds` by `phase` in Grafana). A slow
response: the service's latency panels on **Microservices** and a slow
trace in Tempo. Slow DNS or connect: CoreDNS or the node.

**Act:** as for `SLOLatencyBudgetBurnFast`.

### TLSCertificateExpiringSoon

**Meaning:** an `https://` endpoint's certificate expires in under 21 days
(`warning`) or 7 days (`critical`). None are probed until the domain
exists (roadmap step 03).

**Check:** `kubectl port-forward` as above, then
`curl -s 'localhost:9115/probe?module=http_2xx&target=<url>&debug=true' | grep -i -E 'expiry|issuer'`.
For an ACM certificate: `aws acm describe-certificate --certificate-arn <arn>`,
`RenewalSummary`.

**Act:** ACM renews on its own when its DNS validation record still
exists; restore the CNAME it names. For a cert-manager certificate:
`kubectl describe certificate -A` and the issuer's events.

### SyntheticProberDown

**Meaning:** Prometheus can't reach the blackbox exporter for a probe, so
that endpoint is unwatched (`EndpointDown` can't fire). Alertmanager
holds back the `TargetDown` alert that says the same.

**Check:** `kubectl get pods,endpoints -n monitoring -l app.kubernetes.io/instance=blackbox-exporter`;
the ArgoCD app `blackbox-exporter`.

**Act:** get the exporter running. A config error after a change shows in
its logs; `./scripts/validate.sh` runs `blackbox_exporter --config.check`.

### SyntheticProbesMissing

**Meaning:** Prometheus has no synthetic probe targets at all.

**Check:** `kubectl get probes -n monitoring`. None: the ArgoCD app
`observability-config` (they're in `observability/components/synthetic-probes`).
Present: Prometheus selects Probes by the label
`release: kube-prometheus-stack`; check it's on them, and the
Prometheus Operator's logs for rejected Probes.

**Act:** restore the Probes or their label.

---

## Kafka

The cluster `events` runs in the `kafka` namespace (`streaming/`,
`docs/KAFKA.md`). Grafana has Strimzi's dashboards (**Strimzi Kafka**,
**Strimzi KRaft**, **Strimzi Kafka Exporter** for consumer lag). For Kafka
commands, start the admin pod (it connects as the `kafka-admin` super user)
and delete it afterwards:

```bash
kubectl apply -f streaming/tools/kafka-admin.yaml
kubectl exec -it -n kafka kafka-admin -- bash
bin/kafka-topics.sh $ADMIN --describe --under-replicated-partitions
bin/kafka-consumer-groups.sh $ADMIN --describe --group notification-service
kubectl delete -f streaming/tools/kafka-admin.yaml
```

The services' events are Avro (binary), which Kafka's console tools would
print as garbage. To read or replay them, use the Avro console pod
(`streaming/tools/avro-console.yaml`) the same way: its
`kafka-avro-console-consumer $CONSUME ...` prints them as JSON.

The state Strimzi sees: `kubectl get kafka,kafkanodepool,kafkatopic,kafkauser,kafkaconnect,kafkaconnector -n kafka`
(each has a `Ready` condition and a message when it isn't).

### KafkaOfflinePartitions

**Meaning:** partitions with no leader: every replica of them is down.
Producers to them get errors (order-service logs `order_event_publish_failed`),
consumers stall on them.

**Check:** `kubectl get pods -n kafka -l strimzi.io/cluster=events`. Brokers
not Running: `kubectl describe pod` (a volume that can't attach after a node
moved zones, OOMKilled, image pull). In the admin pod:
`bin/kafka-topics.sh $ADMIN --describe --unavailable-partitions`.

**Act:** get the brokers back; the partitions elect a leader on their own.
Never enable unclean leader election to get a partition back: it accepts
data loss.

### KafkaUnderMinIsrPartitions

**Meaning:** some partitions have fewer in-sync replicas than
`min.insync.replicas` (2). Our producers use `acks=all`, so writes to them
are refused: events are being lost right now (counted in
`order_events_total{outcome="failed"}`, `user_events_total{outcome="failed"}`).

**Check:** which brokers are down or slow (Strimzi Kafka dashboard,
`kubectl get pods -n kafka`); in the admin pod
`bin/kafka-topics.sh $ADMIN --describe --under-min-isr-partitions`.

**Act:** bring the brokers back. Lowering `min.insync.replicas` would accept
writes that one more failure loses; don't, unless losing those events is
explicitly acceptable.

### KafkaNoActiveController

**Meaning:** the KRaft controller quorum has no leader (or more than one).
No leader elections or topic changes can happen; the next broker failure
leaves partitions offline.

**Check:** `kubectl get pods -n kafka -l strimzi.io/pool-name=controller`: a
quorum of three needs two up. Both clusters span two zones, so losing the
zone with two controllers loses the quorum (see `streaming/base/kafka.yaml`).
Controller logs: `kubectl logs -n kafka events-controller-<n>`.

**Act:** restore the controllers (their zone, their volumes). This is the
case for a third availability zone.

### KafkaUnderReplicatedPartitions

**Meaning:** some partitions have fewer copies than configured for more than
10 minutes. Nothing is failing yet; one more broker loss could stop writes
or lose data.

**Check:** a broker down or restarting (a rolling update that's stuck:
`kubectl get kafka events -n kafka -o yaml`, status), or a broker that can't
keep up (Strimzi Kafka dashboard: request queue, network threads busy).

**Act:** restore the broker. If they're all up and a replica keeps falling
behind, the broker is overloaded: more brokers, or move partitions
(Cruise Control).

### KafkaCertificateExpiringSoon

**Meaning:** a Strimzi CA or client certificate expires in under 20 days.
Strimzi renews them 30 days before expiry, so renewal is stuck. When the
cluster CA expires, no client can connect.

**Check:** `kubectl logs -n kafka deploy/strimzi-cluster-operator | grep -i cert`
and the `Kafka` resource's status. For a user certificate, the `KafkaUser`'s
status.

**Act:** fix what blocks the operator (it is down, or a reconciliation fails
on something else first). A manual renewal: annotate the CA secret with
`strimzi.io/force-renew=true`.

### KafkaMetricsMissing

**Meaning:** Prometheus has had no broker metrics for 15 minutes. Either the
brokers are down (then `KafkaOfflinePartitions` would follow, but can't
fire without metrics) or the scrape is broken.

**Check:** `kubectl get pods -n kafka`; then the PodMonitor
`kafka-resources-metrics` and Prometheus' Targets page (`podMonitor/kafka/...`).

**Act:** restore the brokers or the scrape (the metrics port is
`tcp-prometheus`, from `metricsConfig` in the Kafka resource).

### KafkaConsumerLagHigh

**Meaning:** a consumer group is more than 1000 records behind on a topic
for 10 minutes: users get their notifications late.

**Check:** the **Strimzi Kafka Exporter** dashboard (lag per partition). Lag
on one partition only: a stuck or slow consumer there (a record retried in
place: notification-service logs). Lag everywhere: too few consumers, or
each record is slow (notification-service traces in Tempo). In the admin
pod: `bin/kafka-consumer-groups.sh $ADMIN --describe --group notification-service`
shows which consumer owns which partition.

**Act:** scale notification-service up (no further than the topic's
partition count, 6 for `orders`; more consumers than partitions sit idle),
or fix what makes each record slow.

### KafkaDeadLetterRecords

**Meaning:** records went to a `-dlq` topic: notification-service gave up on
them (malformed, or still failing after its retries). Each is a
notification nobody got.

**Check:** why they were parked is in their headers; read those in the
admin pod (the values print as garbage, they're Avro):

```bash
bin/kafka-console-consumer.sh $ADMIN --topic orders-dlq --from-beginning \
  --property print.headers=true --property print.value=false --timeout-ms 10000
```

`kafka_dlt-exception-fqcn` and `kafka_dlt-exception-message` say why;
notification-service logs `event_dead_lettered` with the same offset. The
records themselves, as JSON, in the Avro console pod:
`kafka-avro-console-consumer $CONSUME --topic orders-dlq --from-beginning --timeout-ms 10000`.

**Act:** a malformed record (`PermanentEventException`: not Avro, or a
schema the registry doesn't know) is the producer's bug: fix the producer;
the record can't be replayed as it is. A transient failure (a provider
outage) can be replayed once it's over, in the Avro console pod:

```bash
# 1. The schema ID each record was written with (the number ending each line).
kafka-avro-console-consumer $CONSUME --topic orders-dlq --from-beginning \
  --timeout-ms 10000 --property print.schema.ids=true
# 2. Save them as JSON, key first. The group remembers where it got to, so
#    the next replay starts after these.
kafka-avro-console-consumer $CONSUME --topic orders-dlq --group replay-orders-dlq \
  --from-beginning --timeout-ms 10000 > /tmp/orders-dlq.txt
# 3. Write them back to their topic as Avro under that schema ID (records
#    with different IDs: split the file and run this once per ID).
kafka-avro-console-producer $PRODUCE --topic orders --property value.schema.id=<id> \
  < /tmp/orders-dlq.txt
```

Replayed events keep their eventId, so a notification already sent isn't
sent twice by the same replica.

### KafkaConnectConnectorFailed

**Meaning:** a connector on a Kafka Connect cluster has failed for 15
minutes, despite Strimzi restarting it. In dev that is `events-archive`
(`streaming/components/events-archive`): events stop reaching the S3
archive. They wait in Kafka, which deletes them after 7 days; past that
they are missing from the archive for good.

**Check:** the connector's status and error:

```bash
kubectl get kafkaconnector events-archive -n kafka -o jsonpath='{.status.connectorStatus}'
kubectl logs -n kafka -l strimzi.io/cluster=events-connect --tail=200
```

Usual causes for the archive: AWS refuses the upload (`AccessDenied`: the
IRSA role or its trust doesn't match the ServiceAccount
`events-connect-connect`; `NoSuchBucket`: the bucket in
`streaming/dev/kustomization.yaml` doesn't match tf's
`events_archive_bucket_name`), or a configuration error after an edit to
`archive-connector.yaml`.

**Act:** fix the cause; Strimzi's next automatic restart picks it up, or
restart now: `kubectl annotate kafkaconnector events-archive -n kafka strimzi.io/restart=true`.
The connector continues from its last committed offsets, so nothing still
in Kafka is skipped.

### KafkaConnectTaskFailed

**Meaning:** one task of a connector has failed for 15 minutes; the
partitions it was given aren't copied. Same consequences as
`KafkaConnectConnectorFailed`, for part of the data.

**Check:** the failed task's trace:
`kubectl get kafkaconnector <connector> -n kafka -o jsonpath='{.status.connectorStatus.tasks}'`.
A task failing alone often means one record or one partition it can't
handle, or a transient S3 error the retries didn't outlast.

**Act:** fix the cause and restart the task:
`kubectl annotate kafkaconnector <connector> -n kafka strimzi.io/restart-task=<id>`.

### OutboxPublishingStalled

**Meaning:** order-service has an event in its outbox (the `outbox`
collection in MongoDB, written in the same transaction as the order) that
it hasn't managed to publish for more than 5 minutes. Orders are still
being taken; their notifications are late, not lost.

**Check:** order-service's logs, `order_event_publish_failed` with the
error, and its `order_events_total{outcome="failed"}`. Usual causes: Kafka
is unreachable or refusing writes (the Kafka alerts above), the schema
registry is down (`kubectl get pods -n kafka -l app.kubernetes.io/name=schema-registry`),
or the registry refused a new schema version as incompatible (the error
is a 409 from the registry: a producer change that broke `BACKWARD`
compatibility).

**Act:** fix the cause; the relay retries with backoff (up to 5 minutes
between attempts), oldest events first. An incompatible schema is a code
change to revert or redo with defaults for new fields (docs/KAFKA.md,
"Changing an event").

### OutboxBacklogGrowing

**Meaning:** more than 1000 events are waiting in order-service's outbox for
10 minutes. Either publishing has stopped (see `OutboxPublishingStalled`) or
orders arrive faster than the relay publishes them.

**Check:** `OutboxPublishingStalled` first. If events are being published,
just not fast enough: `rate(order_events_total{outcome="published"}[5m])`
against the order rate.

**Act:** if publishing is stalled, as above. If it is too slow: more
order-service replicas each run the relay (the lease keeps them from
publishing the same event twice), or raise `app.events.outbox.batch-size`
(100 events per poll, every 500 ms).

---

## Autoscaling (KEDA)

KEDA (`docs/KEDA.md`) scales notification-service on its Kafka lag and order-service on
requests per second in the lab and dev. Its state:

```bash
kubectl get scaledobject,hpa -n development          # READY, ACTIVE; the HPA KEDA created
kubectl describe scaledobject <service> -n development   # conditions and events
kubectl logs -n keda deploy/keda-operator --tail=100
```

### KedaScalerErrors

**Meaning:** for 10 minutes KEDA has failed to read a trigger's metric for a
ScaledObject. The service's size no longer follows its load: the HPA keeps the
current count, or KEDA runs the fallback count (notification-service: 1). A
service without a fallback that sits at zero stays there.

**Check:** `kubectl describe scaledobject <service> -n <namespace>` and the
operator's log say which trigger and why. Usual causes: for the Kafka triggers,
Kafka unreachable (the Kafka alerts) or the service's KafkaAccess Secret missing or
renewed with a certificate KEDA hasn't picked up; for the Prometheus trigger,
Prometheus down or the query returning nothing (a renamed metric or label).

**Act:** fix the source; KEDA recovers on its next poll (15 seconds). Meanwhile, if
the service must work, scale it by hand: pause KEDA with the annotation
`autoscaling.keda.sh/paused-replicas: "2"` on the ScaledObject, and remove it after.

### KedaMetricsMissing

**Meaning:** Prometheus has had no metrics from the KEDA operator for 15
minutes. Either KEDA is down, and nothing it scales changes size, or the scrape
is broken, and `KedaScalerErrors` can't fire.

**Check:** `kubectl get pods -n keda`; then the ServiceMonitor `keda-operator` and
Prometheus' Targets page.

**Act:** restore the operator (its ArgoCD application `keda`) or the scrape. While
KEDA is down, services stay at their current size; one at zero stays at zero, so
watch `KafkaConsumerLagHigh`.

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
