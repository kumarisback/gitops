# Amazon MSK or Strimzi?

Roadmap step 14. Steps 12 and 13 run Kafka ourselves, with the Strimzi operator
(`streaming/`, `docs/KAFKA.md`). This step adds the managed alternative, **Amazon MSK
Serverless**, as something you can switch the services to and back in an afternoon, and
compares the two with numbers. Learning notes: tf repo `learning-topics/14-msk-managed.md`.

## What's in the repos

| Piece | Where | What it does |
|---|---|---|
| MSK Serverless cluster | tf `modules/msk`, `01-infra/msk.tf` | Created only with `enable_msk = true`. IAM authentication only, reachable on port 9098 from the pod subnets |
| IAM roles (IRSA) | tf `01-infra/msk.tf` | One per service, allowed exactly what its `KafkaUser` is allowed on Strimzi, and `msk_admin` for creating topics |
| Module test | tf `modules/msk/tests` | `terraform test` with a mocked AWS provider: IAM on, ARN prefixes, one port in |
| Chart MSK mode | `charts/microservice` 0.3.0 | `kafka.msk.bootstrapServers` switches a service to IAM sign-in; `serviceAccount.annotations` carries its role |
| user-service's MSK mode | `apps/components/kafka-msk` | The same for user-service, still deployed with Kustomize (rendered and checked through `tests/kustomize/apps-msk`) |
| Topics | `msk/topics-job.yaml` | MSK has no Topic Operator: a Job creates the same topics as `streaming/base/topics.yaml` |
| The login module | app repo, each service's `build.gradle`; `kafka-connect/Dockerfile` | AWS's `aws-msk-iam-auth`, the only code-side addition; a test per service proves the chart's settings work with it |

The services' code doesn't know which Kafka it talks to: the switch is the environment
variables the chart sets, as the roadmap asked ("if they were written well, this is a
one-line change").

## Try it (dev, one afternoon)

MSK Serverless bills about **$0.75 an hour** from the moment it exists, plus a little per
partition and per GB. Turn it on, try it, turn it off the same day.

1. **Create the cluster.** In the tf repo: `terraform apply -var enable_msk=true` in
   `infrastructure/app-cluster/01-infra` (with the dev var file, as usual). Note the outputs
   `msk_bootstrap_brokers` and `irsa_role_arns` (the `msk_*` entries).
2. **Images.** The services and the Kafka image must include the login module: app
   commit `5859301` or later, built by Jenkins, tags bumped in `apps/dev` and
   `streaming/dev` as usual.
3. **Create the topics:**

   ```bash
   BOOTSTRAP=$(terraform -chdir=<tf repo>/infrastructure/app-cluster/01-infra output -raw msk_bootstrap_brokers)
   sed "s|MSK_BOOTSTRAP_SERVERS|${BOOTSTRAP}|" msk/topics-job.yaml | kubectl apply -f -
   kubectl logs -n msk-admin job/msk-topics -f      # ends with the four topics described
   kubectl delete -f msk/topics-job.yaml
   ```

4. **Switch the services** (a pull request to gitops):
   - `apps/dev/order-service.values.yaml` and `notification-service.values.yaml`:

     ```yaml
     kafka:
       enabled: true
       msk:
         bootstrapServers: <msk_bootstrap_brokers>
     serviceAccount:
       annotations:
         eks.amazonaws.com/role-arn: <irsa_role_arns["msk_order_service"]>   # or msk_notification_service
     ```

   - `apps/dev/kustomization.yaml`: replace `../components/kafka-clients` with
     `../components/kafka-msk`, and add `kafka-msk.yaml` to `resources`, a copy of
     `tests/kustomize/apps-msk/kafka-msk.yaml` with the real bootstrap servers and
     `irsa_role_arns["msk_user_service"]`.
5. **Check.** Create an order (`docs/KAFKA.md`, "Try it"): the notification arrives as before.
   In CloudWatch → Metrics → AWS/Kafka, the cluster shows bytes in per topic and, once
   notification-service has read, `MaxOffsetLag` and `EstimatedMaxTimeLag` for its group.
6. **Switch back, then delete.** Revert the pull request first, then
   `terraform apply -var enable_msk=false`. The other order loses events still on MSK; in
   between, order-service's outbox keeps new ones until Kafka answers again.

What stays on Strimzi meanwhile: the schema registry (it stores its data in the Strimzi
cluster, and the services keep using it), the S3 archive (it copies Strimzi's topics, so it
archives nothing while the services are on MSK), Kafka UI, and the Kafka alerts (Prometheus
can't see MSK's consumers; their lag is in CloudWatch).

## Side by side

| | Strimzi on EKS (steps 12–13) | MSK Serverless (this step) |
|---|---|---|
| **What you run** | Controllers, brokers, their volumes, the operators, upgrades | Nothing: a cluster ARN and an endpoint |
| **Monthly cost in dev** | About $95 (below) | About $570 (below) |
| **Scaling** | You size brokers, add some, move partitions (Cruise Control) | Automatic, up to the quotas: 200 MBps in, 400 MBps out per cluster; 5 MBps in, 10 MBps out per partition |
| **Availability** | Yours to design: dev spans two zones, so losing the zone with two controllers stops Kafka | Three copies across zones, run by AWS |
| **Upgrades** | Strimzi rolls brokers one at a time; you pick the Kafka version and test it | AWS picks and applies versions |
| **Authentication** | TLS client certificates per `KafkaUser`, Kafka ACLs (below) | IAM only: SigV4-signed sign-in with the pod's role, IAM policies |
| **Topic settings** | All of Kafka's | Six: `cleanup.policy` (at creation only), `compression.type`, `max.message.bytes`, `message.timestamp.difference.max.ms`, `retention.bytes`, `retention.ms`. Replication 3 and `min.insync.replicas` 2, fixed |
| **Topics as code** | `KafkaTopic` resources, reconciled by the Topic Operator | Not managed by AWS: a Job here, or a Terraform Kafka provider that can reach the VPC |
| **Monitoring** | Prometheus scrapes everything; Strimzi's dashboards; our alerts | CloudWatch metrics per topic and consumer group (including lag); AWS's Serverless monitoring page lists no Prometheus endpoint |
| **Around Kafka** | Schema registry, Kafka Connect, Kafka UI run next to it (step 13) | AWS's own: Glue Schema Registry (other serializers), MSK Connect (billed per worker capacity) |
| **Lab** | Runs on a laptop | Only in AWS: the lab keeps Strimzi |
| **Lock-in** | Plain Kafka; moves to any cluster | Plain Kafka protocol, but IAM sign-in and IAM policies are AWS-only |

### Cost, worked out

**Strimzi in dev** requests 2.25 vCPU and 9 GiB of memory (three brokers at 0.5 vCPU and
2 GiB, three controllers at 0.25 vCPU and 1 GiB). Memory is the binding resource, about 1.1
m5.large (2 vCPU, 8 GiB, $0.096 an hour on demand): about **$80 a month**, less on the spot
nodes Karpenter prefers. Volumes: 3 × 50 GiB + 3 × 10 GiB of gp3 at $0.08 per GB-month,
**$14.40**. Replication between zones adds $0.02 per GB copied, a few cents at this volume.
About **$95 a month**, before the registry and Connect.

**MSK Serverless**, at AWS's published example rates: 744 hours × $0.75 = **$558**; our 11
partitions × 744 hours × $0.0015 = **$12.28**; data in at $0.10 per GB and out at $0.05 per
GB, cents at this volume. About **$570 a month**, or about **$4 for a five-hour
afternoon**. Check [the pricing page](https://aws.amazon.com/msk/pricing/) for your region.

So for a small cluster the bill is about six times higher managed. What it buys is the work
not done: no broker sizing, no rolling upgrades, no volume or zone design, no operator to
keep current, no pager for Kafka itself. At this project's size Strimzi wins on cost and on
learning value; for a team without Kafka experience running production traffic, the
managed service is often the cheaper option once people's time counts. MSK Provisioned
(brokers you size, still managed) sits in between and supports Prometheus monitoring and
more settings.

### Authentication: two different mechanisms

**Strimzi (mutual TLS).** Strimzi runs a clients certificate authority. For each
`KafkaUser` it issues a certificate whose subject is `CN=<user>`; the client presents it in
the TLS handshake, and the broker knows who it is without a password. What that user may do
is a list of Kafka ACLs (topic `orders`: Write, Describe), stored in the cluster's metadata
and managed through the `KafkaUser`. Credentials are files (a certificate and key), renewed
by Strimzi and copied to the services by the Access Operator.

**MSK (SASL with IAM).** There are no Kafka users. The client signs a sign-in request with
its AWS credentials (Signature Version 4, like any AWS API call) and sends it over TLS with
the `AWS_MSK_IAM` SASL mechanism; MSK checks it with IAM. In a pod those credentials come from
IRSA: the ServiceAccount's annotation names a role, EKS mounts a token, and the AWS SDK
exchanges it with STS for short-lived credentials. What the client may do is an IAM policy
with `kafka-cluster:*` actions on ARNs:

| Strimzi ACL | MSK IAM action |
|---|---|
| (being connected at all) | `kafka-cluster:Connect` (and `DescribeCluster`) on the cluster |
| topic Write | `kafka-cluster:WriteData` on `topic/<cluster>/<uuid>/orders`, plus `WriteDataIdempotently` on the cluster for idempotent producers |
| topic Read | `kafka-cluster:ReadData` on the topic |
| topic Describe | `kafka-cluster:DescribeTopic` |
| group Read | `kafka-cluster:AlterGroup` and `DescribeGroup` on `group/<cluster>/<uuid>/<group>` |
| topic Create | `kafka-cluster:CreateTopic` |

Nothing secret is stored or copied; credentials expire within hours and the client signs in
again. The price is that every client needs AWS's login module (Java here; libraries exist
for other languages) and AWS credentials, so a tool from outside AWS can't simply connect.

## When to choose which

- **Strimzi** when the cluster must also run outside AWS (the lab), when you need settings
  or features MSK doesn't offer, when Kafka is central enough that the team will know it
  well anyway, or when cost at small scale matters.
- **MSK Serverless** for spiky or small production workloads where nobody should be on call
  for Kafka, inside AWS, with clients that can use IAM.
- **MSK Provisioned** for steady, larger workloads that want managed brokers with more
  control (broker sizes, Prometheus metrics, more configuration).

This project keeps Strimzi as its Kafka and MSK as a tested exit: the services can move by
configuration, the topics are scripted, and the IAM policies mirror the ACLs.

Sources: [MSK pricing](https://aws.amazon.com/msk/pricing/),
[MSK quotas](https://docs.aws.amazon.com/msk/latest/developerguide/limits.html),
[MSK Serverless configuration](https://docs.aws.amazon.com/msk/latest/developerguide/serverless-config.html),
[Monitoring MSK Serverless](https://docs.aws.amazon.com/msk/latest/developerguide/serverless-monitoring.html).
