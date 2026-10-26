# Kafka: services talking through events

Roadmap step 12. Until now the services only called each other directly
(user-service asks order-service for a user's orders). From this step,
some things happen through **events**: order-service announces "an order was
created" on a Kafka topic and doesn't care who listens; a new service,
**notification-service**, listens and notifies the user. Adding a second
listener later (billing, analytics) changes nothing in order-service.

```
POST /api/orders ──► order-service ──OrderCreated──►  topic orders  ──► notification-service ──► "email"
POST /api/auth/signup ► user-service ─UserRegistered─► topic users ──┘         │
                                                                               └─ gave up ─► orders-dlq / users-dlq
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
| Metrics, alerts | `streaming/base/kafka-metrics.yaml`, `podmonitors.yaml`, `kafka-alerts.yaml` | Broker metrics, consumer lag, 8 alerts (runbooks: `docs/runbooks.md#kafka`) |

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

**The known gap.** order-service saves the order, then publishes the event
without waiting. If Kafka is down the order exists and the event is lost
(logged and counted, `order_events_total{outcome="failed"}`). Step 13's
outbox closes this: the event is stored with the order and published from
there.

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
| lab | 1 combined node, replication 1 | Fits on a laptop; shows how Kafka works, not how it survives failures |
| dev | production shape | The failure exercises need three brokers |
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
   `echo 'not json' | bin/kafka-console-producer.sh $ADMIN --topic orders`.
   notification-service logs `event_dead_lettered` and
   `KafkaDeadLetterRecords` fires; read it back as in the runbook.

4. **Retries, then the dead-letter topic.** Set
   `APP_NOTIFICATIONS_SIMULATEDFAILURERATE=1` (`app.notifications.simulated-failure-rate`) on notification-service
   (`extraEnv` in its values file) and create an order: three retries, then
   `orders-dlq`. Remove it again.

On dev (three brokers), also: delete a broker pod while creating orders
(nothing is lost; `KafkaUnderReplicatedPartitions` comes and goes), and scale
notification-service to 8 replicas to see two of them get no partition
(`bin/kafka-consumer-groups.sh $ADMIN --describe --group notification-service`).

## Deploying to dev

1. tf: apply `shared-services` (the `notification-service` ECR repository)
   and `app-cluster/01-infra` (the empty `mongodb` and `jwt-signing-key`
   secrets).
2. Set the secrets' values: `scripts/set-secret.sh dev jwt-signing-key` and
   `scripts/set-secret.sh dev mongodb` (tf repo).
3. Merge the app repo; Jenkins builds the images. Bump the tags of
   user-service, order-service and notification-service in dev with the
   gitops job (UPDATE_IMAGE). user-service and order-service go together:
   the new order-service accepts only the new user-service's tokens.
4. Merge gitops; ArgoCD installs Strimzi, the cluster and the services.
