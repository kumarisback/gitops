# KEDA: scaling on events, down to zero

Roadmap step 15. Until now every service scaled on CPU (a HorizontalPodAutoscaler from
`charts/microservice`, or `apps/base/*/hpa.yaml`). That fits an API, where more requests
mean more CPU. It doesn't fit notification-service: its work is the backlog in Kafka, and a
consumer waiting on a slow e-mail provider uses almost no CPU while that backlog grows.
**KEDA** scales on the signal that matters (Kafka lag, a Prometheus query, a queue's
length) and can scale to zero, which an HPA can't.

```
Kafka (lag of group notification-service) ─┐
Prometheus (order-service requests/s) ─────┼─► KEDA operator ──► HPA it creates ──► Deployment replicas
                                           │      │                ▲
                                           │      └─ 0 ↔ 1 itself   └─ external metrics API (KEDA metrics server)
```

KEDA doesn't replace the HPA, it **feeds** it: for each `ScaledObject` it creates an HPA
whose metrics come from KEDA's metrics server, and it handles the one thing an HPA can't,
going from 0 to 1 replica and back.

## The pieces

| Piece | Where | What it does |
|---|---|---|
| KEDA 2.21 | `addons/applications/keda.yaml`, `addons/values/common/keda.yaml` | Operator, metrics server, admission webhooks, in every environment; scraped by Prometheus |
| Chart support | `charts/microservice` 0.4.0, `autoscaling.keda` | A `ScaledObject` instead of the CPU HPA; `minReplicas: 0` allowed only with it; a `TriggerAuthentication` from the service's Kafka certificate; `podDisruptionBudget.maxUnavailable` |
| notification-service | `apps/{local,dev}/notification-service.values.yaml` | Two Kafka triggers (orders, users): 0 to 6 replicas in dev, 0 to 3 in the lab |
| order-service | `apps/{local,dev}/order-service.values.yaml` | Prometheus (requests per second) and CPU triggers, 2 to 10 in dev; staging and prod keep the plain CPU HPA |
| Alerts | `observability/base/autoscaling-alerts.yaml`, `service-alerts.yaml` | `KedaScalerErrors`, `KedaMetricsMissing`; `ServiceUnavailable` no longer fires for a service scaled to zero on purpose |
| Exercise knob | notification-service `app.notifications.simulated-latency` | Makes every send slow, like a struggling provider, to build a backlog |

## Design choices, and why

**Lag, per partition count.** The Kafka trigger asks for one replica per 50 records
waiting (`lagThreshold`), but never more than the topic has partitions: a partition is read
by one consumer of a group at a time, so a seventh consumer of `orders` would sit idle.

**One trigger per topic.** notification-service reads `orders` and `users`. A single trigger
without a topic would work out the topics from the group's committed offsets, but a group
that has been at zero since before it ever committed has none, and would never be woken up.
Naming each topic avoids that; the HPA takes whichever trigger asks for more.

**Activation versus scaling.** Going from 0 to 1 is KEDA's decision (any lag above
`activationLagThreshold`, 0 here); from 1 to N it's the HPA's, on the metric. Back to 0
happens after `cooldownPeriod` (5 minutes) with every trigger idle.

**The cost of zero is a cold start.** The first event after a quiet period waits for KEDA's
next poll (15 seconds) and a Spring Boot start (20–40 seconds). For notifications that's
fine; for an API it isn't, so order-service never goes below its minimum.

**When KEDA can't see.** If KEDA can't read the lag (Kafka unreachable, a broken
certificate), an HPA would simply stop changing anything: a service at zero would stay at
zero with work piling up. notification-service has `fallbackReplicas: 1`: after three failed
reads it runs one consumer. `KedaScalerErrors` says when that happens.

**How KEDA signs in to Kafka.** As the service it scales: the `TriggerAuthentication` uses the
service's own certificate from its KafkaAccess Secret, and that KafkaUser may already describe
its group and topics. No new identity, no new ACLs. (On MSK, step 14, the trigger would need
IAM instead; left as an exercise.)

**Disruption budget.** A budget of "at least one available" on a service that often runs one
pod blocks every node drain (Karpenter's consolidation included). notification-service uses
"at most one unavailable" instead: its records simply wait in Kafka while the pod moves.

**Alerts.** `ServiceUnavailable` used to fire when a Deployment had no ready pods; now only
while some are wanted (`kube_deployment_spec_replicas > 0`), so a deliberate zero is quiet
and a pod that never becomes ready after KEDA asked for one still pages. `KafkaConsumerLagHigh`
still catches a backlog nobody is working on.

## Try it in the lab

After `scripts/sync-local-stack.rb`: `kubectl get scaledobject,hpa -n development` shows
both ScaledObjects `READY` and `ACTIVE`, and notification-service at 0 replicas once Kafka
is drained for 5 minutes.

1. **Slow the provider down.** Add to `apps/local/notification-service.values.yaml`:

   ```yaml
   extraEnv:
     - name: APP_NOTIFICATIONS_SIMULATEDLATENCY
       value: 200ms
   ```

   and sync again. Each consumer now handles about 5 events a second.

2. **Send a burst of 10,000 events**, in the Avro console pod
   (`streaming/tools/avro-console.yaml`):

   ```bash
   ID=$(curl -s http://schema-registry:8080/apis/ccompat/v7/subjects/orders-value/versions/latest | sed 's/.*"id":\([0-9]*\).*/\1/')
   for i in $(seq 1 10000); do
     printf 'burst-%s\t{"eventId":"burst-%s","occurredAt":%s000,"orderId":"burst-%s","userId":"u-1","item":"load test","amount":1.0,"status":"CREATED"}\n' "$i" "$i" "$(date +%s)" "$i"
   done > /tmp/burst.txt
   kafka-avro-console-producer $PRODUCE --topic orders --property value.schema.id=$ID < /tmp/burst.txt
   ```

   (If the image has no `curl`, the schema ID is the number ending each line of
   `kafka-avro-console-consumer $CONSUME --topic orders --from-beginning --max-messages 1 --property print.schema.ids=true`.)

3. **Watch it scale:** `kubectl get deploy notification-service -n development -w` goes
   0 → 1 within about 15 seconds, then 3 (the lab's maximum). The **Strimzi Kafka Exporter**
   dashboard shows the lag falling; `kubectl get hpa keda-hpa-notification-service -n development`
   shows the metric against its target. When the lag is gone, 5 minutes later, back to 0.

4. **Now the same with CPU.** Set `autoscaling.keda.enabled: false`, `minReplicas: 1`,
   `maxReplicas: 3` (the chart's CPU HPA, 70%), sync, and send the burst again. The pod sits
   at a few percent CPU, sleeping in the simulated provider, and the HPA never adds a
   second: the backlog takes three times as long. That is the case for scaling on the work
   rather than on its side effects.

5. **The Prometheus trigger.** Load order-service:

   ```bash
   kubectl run load -n development --rm -it --image=busybox:1.37 --restart=Never -- \
     sh -c 'while true; do wget -q -O /dev/null http://order-service/api/orders/status; done'
   ```

   Above 20 requests a second (`sum(rate(http_server_requests_seconds_count{job="order-service"}[2m]))`
   in Grafana) it goes to 2 replicas, CPU or not. Stop the load: back to 1 after the HPA's
   5-minute scale-down window.

Remove the latency setting afterwards.

## Deploying to dev

KEDA is an add-on like the others: merging gitops installs it (its CRDs first), then the
services' ScaledObjects. notification-service's image must include the latency setting only
for the exercise; nothing else changes in the app. Compare dev (KEDA) with staging (CPU HPA)
for order-service under the load tests of step 40.
