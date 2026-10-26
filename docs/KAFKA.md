# Kafka: services talking through events

Roadmap steps 12 and 13. Until step 12 the services only called each other
directly (user-service asks order-service for a user's orders). From then
on, some things happen through **events**: order-service announces "an
order was created" on a Kafka topic and doesn't care who listens; a new
service, **notification-service**, listens and notifies the user. Adding a
second listener later (billing, analytics) changes nothing in order-service.

Step 13 adds what a real event platform needs around Kafka: every event has
a **schema** in a registry, so a producer can't silently break its
consumers; order-service stores each event **with its order** and publishes
it from there (the transactional outbox), so no event is lost when Kafka is
down; and **Kafka Connect** copies every event to S3, where it outlives the
topics' week of retention.

```
POST /api/orders ──► order-service ── order + event, one transaction ──► MongoDB
                          └─ outbox relay ──OrderCreated──► topic orders ──┬──► notification-service ──► "email"
POST /api/auth/signup ► user-service ─UserRegistered─────► topic users ───┤          └─ gave up ─► orders-dlq / users-dlq
                                                                          └──► Kafka Connect ──► S3 archive (dev)

        every value is Avro; its schema lives in the schema registry, which refuses incompatible changes
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Strimzi operator | `addons/streaming/strimzi-kafka-operator.yaml` | Runs Kafka from Kubernetes resources: the cluster, topics, users |
| Kafka cluster `events` | `streaming/base/kafka.yaml` | KRaft (no ZooKeeper). Cloud: 3 controllers + 3 brokers across zones; lab: 1 node |
| Topics | `streaming/base/topics.yaml` | `orders` (6 partitions), `users` (3), and a `-dlq` twin for each |
| Users and ACLs | `streaming/base/users.yaml` | One TLS identity per service, allowed only what it needs |
| Access Operator | `addons/streaming/strimzi-access-operator.yaml` | Copies each service's connection (address, certificate, key, CA) into its namespace |
| KafkaAccess | `apps/components/kafka-clients` | "order-service needs a connection as KafkaUser order-service" |
| notification-service | app repo; `apps/<env>/notification-service.values.yaml` | The consumer, deployed with our Helm chart |
| Schema registry | `streaming/base/schema-registry.yaml` | Apicurio Registry, storing its data in Kafka: every event schema, versioned; refuses a change that isn't backward compatible |
| Outbox | order-service `outbox/` | Saves each event with its order in one MongoDB transaction; a relay publishes it |
| Events archive | `streaming/components/events-archive`; app repo `kafka-connect/`; tf `01-infra/streaming.tf` | Kafka Connect with an S3 sink: every event into S3, kept a year (dev) |
| Kafka UI | `addons/streaming/kafka-ui.yaml` | Read-only web UI: topics, messages decoded with the registry, consumer groups, schemas |
| Tools | `streaming/tools/` | Admin pod (Kafka's CLI as a super user); Avro console pod (read and replay events as JSON) |
| Metrics, alerts | `streaming/base/kafka-metrics.yaml`, `podmonitors.yaml`, `kafka-alerts.yaml` | Broker, Connect and outbox metrics, consumer lag, 12 alerts (runbooks: `docs/runbooks.md#kafka`) |

Everything about Kafka is a file in Git: a new topic is a pull request, and
deleting a `KafkaTopic` deletes the topic. Topics are never created by a
client (`auto.create.topics.enable: false`): a typo is an error, not a new
topic.

## Design choices, and why

**Partitions.** A topic is split into partitions; a consumer group reads each
partition with one consumer at a time, and order is guaranteed only within
a partition. So `orders` has 6 partitions: at most 6 notification-service
replicas can share the work (its autoscaler stops at 6), and a seventh would
sit idle. The count can be raised later but never lowered, and raising it
changes which partition a key lands in, so it's chosen with headroom.

**Keys.** order-service keys each event by order ID: every event about one
order lands in the same partition, in order, while different orders spread
over all partitions. Keying by user ID would order a user's events but let
one busy user overload one partition.

**Delivery.** Producers wait for all in-sync replicas (`acks=all`) and are
idempotent (a retried send can't create a duplicate). Consumers commit an
offset only after handling the record, so a record is delivered **at least
once**: after a crash or rebalance it can come again. Each event has an
`eventId`, and notification-service skips one it already sent. A failure
that may pass is retried (1s, 2s, 4s), then the record goes to the topic's
`-dlq` twin with the exception in its headers, so one bad record never
blocks its partition.

**The outbox (step 13).** In step 12 order-service saved the order, then
published the event: if Kafka was down, the order existed and its event was
lost. Saving and publishing can't be one transaction (MongoDB and Kafka
don't share one), so now order-service writes the order **and** an `outbox`
document in one MongoDB transaction: both or neither. A relay in every
replica publishes due outbox events, oldest first, taking a 30-second lease
on each so two replicas don't send the same one; on failure it backs off (2s,
4s, ... up to 5 minutes) and keeps the event. Sent events are marked and
deleted 7 days later. While Kafka is down, orders are still taken and their
events wait (`outbox_pending`, `OutboxPublishingStalled`). Transactions need
a MongoDB replica set: Atlas clusters are, and the lab's MongoDB starts as a
one-member replica set. The relay can send an event twice (it crashes after
sending, before marking), which consumers already handle by `eventId`.

**Schemas (step 13).** Events were JSON, which any producer change could
break without anyone noticing until a consumer failed. Now values are
**Avro**, a compact binary format with a schema: order-service's
`src/main/avro/OrderCreated.avsc`, user-service's `UserRegistered.avsc`.
Each record starts with the ID of the schema it was written with, kept in
the **schema registry** (Apicurio, through its Confluent-compatible API, so
the standard Confluent serializers work). The registry's global rules
(set by the `schema-registry-rules` Job) make every new version **backward
compatible**: a consumer on the new schema can still read the old events.
notification-service reads each record in the schema it was written with
(no generated classes), so producers can add fields without redeploying it.
Change data capture (Debezium streaming database changes into Kafka) waits
for step 23, which adds PostgreSQL.

**The archive (step 13).** Topics keep events for 7 days. Kafka Connect, a
framework for copying data between Kafka and other systems with ready-made
connectors, runs Aiven's S3 sink in dev: every record of `orders` and
`users`, byte for byte, as gzipped JSON lines in S3, kept a year
(`streaming/components/events-archive/archive-connector.yaml` describes the
files). The Connect workers write with an IRSA role that can only upload to
that bucket.

**Security.** The only listener is TLS, and every client proves who it is
with a certificate issued by Strimzi (`KafkaUser`). ACLs allow each service
only its own topics: order-service may write `orders` and nothing else;
notification-service may read `orders` and `users` and write the
dead-letter topics. The certificates are renewed automatically, and the
Access Operator keeps the copies in the services' namespace current.

**Durability across zones.** Replication factor 3 and `min.insync.replicas`
2: losing one broker loses no acknowledged data and doesn't stop writes.
The VPCs span two zones, though, so pods spread 2+1, and losing the zone
with two controllers stops Kafka until it's back. A third zone is what it
takes to survive a zone outage.

## Where it runs

| Environment | Kafka | Why |
|---|---|---|
| lab | 1 combined node, replication 1; registry and UI, no archive | Fits on a laptop; shows how Kafka works, not how it survives failures |
| dev | production shape, plus the S3 archive | The failure exercises need three brokers |
| staging, prod | not yet | Three brokers and three controllers cost real money; `addons/streaming/kustomization.yaml` says how to turn it on |

Where Kafka isn't deployed, the services run exactly as before: event
publishing is off (`app.events.enabled=false`) and notification-service
isn't deployed.

## The order API now needs a sign-in token

Creating orders made it obvious that order-service's API was open to anyone
who could reach the load balancer, and that the user ID came from the
request body. Now:

- user-service signs sign-in tokens with an RSA key (`jwt-signing-key`
  Secret) and publishes the public key at `/api/auth/jwks.json`;
- order-service accepts only requests with a valid token from user-service,
  and the order belongs to whoever the token names. `GET /api/orders/status`
  (the synthetic check) and actuator stay open.

## Try it in the lab

After `scripts/sync-local-stack.rb` (Kafka takes a few minutes to start:
`kubectl get kafka -n kafka -w` until `READY` is `True`):

1. **Sign up, sign in, create an order**, through Traefik on localhost:

   ```bash
   curl -s localhost/api/auth/signup -H 'Content-Type: application/json' -d '{"username":"asha","password":"a-long-password"}'
   TOKEN=$(curl -s localhost/api/auth/signin -H 'Content-Type: application/json' -d '{"username":"asha","password":"a-long-password"}' | jq -r .token)
   curl -s localhost/api/orders -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{"item":"Kafka book","amount":42.5}'
   kubectl logs -n development deploy/notification-service | grep notification_sent
   ```

   Two notifications: the welcome (`UserRegistered`) and the order. In Grafana
   → Explore → Tempo, the trace of the POST continues through Kafka into
   notification-service.

2. **Watch lag build up and drain.** Stop the consumer
   (`kubectl scale deploy notification-service -n development --replicas=0`;
   with ArgoCD reconciling, turn off its auto-sync first), create twenty
   orders, look at the **Strimzi Kafka Exporter** dashboard, then scale back
   to 1.

3. **Send a poison record to the dead-letter topic.** In the admin pod
   (`streaming/tools/kafka-admin.yaml`):
   `echo 'not avro' | bin/kafka-console-producer.sh $ADMIN --topic orders`.
   notification-service logs `event_dead_lettered` and
   `KafkaDeadLetterRecords` fires; read it back as in the runbook.

4. **Retries, then the dead-letter topic.** Set
   `APP_NOTIFICATIONS_SIMULATEDFAILURERATE=1` (`app.notifications.simulated-failure-rate`) on notification-service
   (`extraEnv` in its values file) and create an order: three retries, then
   `orders-dlq`. Remove it again.

5. **Look around in Kafka UI.**
   `kubectl port-forward svc/kafka-ui 8080:80 -n kafka`, then
   http://localhost:8080: the order you created, decoded from Avro; the
   `orders-value` schema; notification-service's lag.

6. **Take Kafka away from order-service; lose nothing.** Revoke its right to
   write `orders`:

   ```bash
   kubectl patch kafkauser order-service -n kafka --type json \
     -p '[{"op":"replace","path":"/spec/authorization/acls/0/operations","value":["Describe"]}]'
   ```

   Create orders: they succeed, order-service logs
   `order_event_publish_failed` (not authorized), `outbox_pending` grows, and
   `OutboxPublishingStalled` fires after about 10 minutes. Give the right
   back (the same command with `["Write","Describe"]`, or run
   `scripts/sync-local-stack.rb` again): the relay sends everything, oldest
   first, and the notifications arrive late but complete.

7. **Try to break a consumer.** Ask the registry whether a version of
   `OrderCreated` without `item` (which notification-service needs, and
   which has no default) may replace the current one:

   ```bash
   kubectl port-forward svc/schema-registry 8081:8080 -n kafka &
   curl -s -X POST localhost:8081/apis/ccompat/v7/compatibility/subjects/orders-value/versions/latest \
     -H 'Content-Type: application/vnd.schemaregistry.v1+json' \
     -d '{"schema":"{\"type\":\"record\",\"name\":\"OrderCreated\",\"namespace\":\"com.example.events.orders\",\"fields\":[{\"name\":\"eventId\",\"type\":\"string\"},{\"name\":\"occurredAt\",\"type\":{\"type\":\"long\",\"logicalType\":\"timestamp-millis\"}},{\"name\":\"orderId\",\"type\":\"string\"},{\"name\":\"userId\",\"type\":\"string\"},{\"name\":\"amount\",\"type\":\"double\"},{\"name\":\"status\",\"type\":\"string\",\"default\":\"CREATED\"},{\"name\":\"currency\",\"type\":\"string\"}]}"}'
   ```

   `"is_compatible": false`: the new `currency` field has no default, so
   the new schema can't read old events. Give it `"default": "EUR"` and it
   becomes compatible. Removing `item` is allowed by `BACKWARD` alone, which
   is why the `.avsc` files say never to remove a field without a default.

On dev (three brokers), also: delete a broker pod while creating orders
(nothing is lost; `KafkaUnderReplicatedPartitions` comes and goes), and scale
notification-service to 8 replicas to see two of them get no partition
(`bin/kafka-consumer-groups.sh $ADMIN --describe --group notification-service`).
And the archive: a few minutes after creating orders,
`aws s3 ls s3://microservices-dev-events-archive-602367507570/orders/ --recursive`
lists the files; `aws s3 cp <file> - | gunzip` shows one JSON line per
event.

## Changing an event

A producer's schema change reaches every consumer, so it follows rules,
enforced by the registry (`BACKWARD`) and the producers' schema tests:

- **Add a field with a default.** Old events, which lack it, read as the
  default.
- **Never rename a field, change its type, or remove a field without a
  default.** A consumer that needs it would fail on every new event.
- **A breaking change is a new event** on a new topic (`orders.v2`),
  published alongside the old one until every consumer has moved.

The producer registers the new version itself on its first send
(`auto.register.schemas`). If the registry refuses it, the send fails: in
order-service the event stays in the outbox and `OutboxPublishingStalled`
fires, so a breaking change is noticed before anything is lost.

## Deploying to dev

1. tf: apply `shared-services` (the `notification-service` and
   `kafka-connect` ECR repositories) and `app-cluster/01-infra` (the empty
   `mongodb` and `jwt-signing-key` secrets; the events archive bucket and
   its IRSA role, `enable_events_archive = true` in `dev.tfvars`).
2. Set the secrets' values: `scripts/set-secret.sh dev jwt-signing-key` and
   `scripts/set-secret.sh dev mongodb` (tf repo). The outbox needs MongoDB
   transactions, so the URI must point at a replica set (any Atlas
   cluster is one).
3. Merge the app repo; Jenkins builds the images. Bump the tags of
   user-service, order-service and notification-service in dev with the
   gitops job (UPDATE_IMAGE). user-service and order-service go together:
   the new order-service accepts only the new user-service's tokens, and
   notification-service reads only the Avro events they now publish. The
   `kafka-connect` image's tag is in `streaming/dev/kustomization.yaml`;
   set it to the commit Jenkins built.
4. Merge gitops; ArgoCD installs Strimzi, the cluster, the schema registry,
   Kafka Connect and the services.
