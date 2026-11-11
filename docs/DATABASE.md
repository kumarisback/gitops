# The database, properly: PostgreSQL on Amazon RDS

Roadmap step 23. Until now the only relational database here was Unleash's PostgreSQL
(step 22), a StatefulSet with one disk: if its node or zone goes, so do the flags, and nobody
backs it up. This step builds the production version on **Amazon RDS for PostgreSQL**,
switches Unleash to it in an environment that wants it, and streams Unleash's changes into
Kafka with **Debezium** (change data capture, moved here from step 13). The services
themselves stay on MongoDB; Unleash is the PostgreSQL user.

RDS costs money while it runs, so it is off by default (tf `enable_rds`); everything below
is in Git, tested, and switched on with a few lines when you do the step's exercises.

```
                         ┌───────────── VPC, private data subnets ─────────────┐
 Unleash ── TLS, verified ──► [RDS Proxy, optional] ──► RDS primary ══sync══► standby (other zone)
   ▲  Secret unleash-db                                    │  ╲
   │  (External Secrets, every 5 min)                       │   ╲─async─► read replica (optional)
   │      ▲                                                 │
   │      └── Secrets Manager: the master password, rotated by RDS
   └── Reloader restarts Unleash when that Secret changes   │
                                                            │ logical replication slot (WAL)
 Kafka Connect: Debezium ◄──────────────────────────────────┘
      └──► topic flags.public.events ──► the events archive (S3), anything else that listens
 CloudWatch ──► alarms (SNS e-mail) and Grafana's RDS dashboard
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| The instance | tf `modules/database`, `01-infra` (`enable_rds`, `rds_multi_az`, `rds_read_replica`, `rds_proxy`, `database_alarm_email`) | PostgreSQL 17, Multi-AZ, encrypted gp3 that grows on its own, a parameter group (TLS forced, logical replication, slow-query log), a master password RDS keeps in Secrets Manager and rotates, IAM authentication allowed, Database Insights, Enhanced Monitoring, logs to CloudWatch, backups with point-in-time recovery, deletion protection. Optional read replica and RDS Proxy |
| Who may connect | tf `modules/database` security groups | The cluster's security group only, PostgreSQL's port only (and RDS Proxy's group, when there is one) |
| Alarms | tf `modules/database` (`aws_cloudwatch_metric_alarm.rds`), `01-infra` SNS topic | CPU, free storage, connections, free memory, replication slot lag; replica lag with a replica |
| Unleash on RDS | `feature-flags/components/rds` | Removes the in-cluster PostgreSQL; Unleash connects to RDS with TLS and the certificate checked; its credentials come from RDS's own secret, through a SecretStore only this namespace can use |
| The certificates | `feature-flags/components/rds/ca-bundle.pem`, `scripts/update-rds-ca.sh` | AWS's RDS certificate authorities (all regions) and Amazon's four roots (RDS Proxy's certificate is from ACM) |
| Restart on rotation | `addons/feature-flags/reloader.yaml` (Reloader 1.4) | Restarts Unleash when Secret `unleash-db` changes; may read Secrets only in namespace `feature-flags`; alert `CredentialReloadFailed` if a restart fails |
| Change data capture | `streaming/components/flag-changes` (+ `flag-changes-rds`), `feature-flags/components/cdc`, app `kafka-connect/` (Debezium 3.7) | Every insert into Unleash's audit table `events` becomes a record on `flags.public.events`, archived to S3 with the other events |
| Dashboards | `observability/components/cloudwatch`, tf `grafana_cloudwatch` role | Grafana's CloudWatch data source (read-only role) and the *RDS PostgreSQL* dashboard |

## Design choices, and why

**Multi-AZ is not a read replica.** Multi-AZ keeps a *synchronous* standby in another
availability zone: every commit is on both disks before it's acknowledged. The standby takes
no queries; it exists to take over (same endpoint, the DNS name moves) when the primary's
instance, disk or zone fails, typically in one to two minutes. A read replica is
*asynchronous*: it applies the primary's changes a little later (`ReplicaLag`), takes
read-only queries, and is for spreading reads, not for surviving a failure (promoting one is
a manual step that loses whatever it hadn't received). Multi-AZ is on by default; the replica
is off, because nothing here reads enough to need one: Unleash is one process with a small
pool, and the services use MongoDB. The roadmap's "route reads from order-service" has no
reads to route; `rds_read_replica` creates one for the replica-lag exercise, and learning
topic 23 says what a service would need to use it (a second connection pool, and accepting
stale reads).

**The parameter group.** Only what the defaults don't give: `rds.force_ssl = 1` (an
unencrypted connection is refused; the default since PostgreSQL 15, written down so a
default can't change it), `rds.logical_replication = 1` (for Debezium; it costs a little more
write-ahead log), and `log_min_duration_statement = 500` (every statement slower than half a
second is logged, in CloudWatch Logs). `max_connections`, `shared_buffers` and `work_mem`
keep RDS's defaults, which are formulas of the instance's memory: on db.t4g.micro that is
about 80 connections. Raise the class before tuning them.

**Connection pooling.** Every PostgreSQL connection is a process with its own memory. With
Kubernetes, connections multiply: replicas × each replica's pool. Ten pods with a pool of 10
already exceed db.t4g.micro's 80, and an autoscaler adds pods exactly when the database is
busiest. Two remedies: **RDS Proxy** (`rds_proxy = true`; managed, multiplexes many client
connections onto few database ones, keeps clients connected through a Multi-AZ failover,
billed per vCPU of the instance) or **PgBouncer** in the cluster (free, more knobs, one more
thing to run and keep highly available). Unleash, one pod with a pool of at most four, needs
neither; the proxy is there for the exercise, and the `connections` alarm and dashboard show
the number that matters. Change data capture can't go through a proxy (it doesn't carry
replication connections): Debezium always connects to the instance.

**Credentials and rotation.** `manage_master_user_password` makes RDS generate the master
password, keep it in a Secrets Manager secret (`rds!db-…`) and rotate it every seven days;
nobody types it, and Terraform never holds it. External Secrets copies it into Secret
`unleash-db` every 5 minutes, through a SecretStore that belongs to namespace
`feature-flags` and whose IAM role may read that one secret; the cluster-wide store, which
any namespace's ExternalSecret may use, can't read it. Reloader restarts Unleash when the
Secret changes, because a pod reads its environment only when it starts. **The window:** RDS changes the password at once; connections Unleash already
has stay signed in, but a new one fails until the Secret is refreshed and Unleash restarted:
up to about five minutes, once a week. Unleash keeps serving flags from connections it has,
and the services keep their last answers anyway. To close the window, either refresh right
after a rotation (`kubectl -n feature-flags annotate externalsecret unleash-db
force-sync=$(date +%s) --overwrite`), shorten `refreshInterval` (cost: Secrets Manager API
calls), or move to **IAM database authentication** (enabled on the instance): a client signs
in with a 15-minute token made from its IAM role, and there is no password to rotate. Unleash
can't make such tokens itself, which is why it uses the password; learning topic 23's
exercise does IAM auth with a client that can. **Known gap:** Unleash signs in as the
master user. The instance holds only its database, which its owner would control anyway,
but the master user can also create roles and replicate; `docs/ISSUES.md` #17 has the fix
(its own role, rotated with alternating users, which also removes the window).

**Encryption.** At rest: the disk, its snapshots and backups are encrypted with KMS
(`storage_encrypted`; AWS's managed key; a customer-managed key would let you control and
audit who may decrypt, and share snapshots across accounts, for $1 a month). In transit: RDS
refuses plain connections, and Unleash doesn't just encrypt, it **verifies**: the server's
certificate must chain to `ca-bundle.pem` and name the host it connected to (Node's
`rejectUnauthorized`, PostgreSQL's `verify-full` for Debezium). Encryption without
verification stops eavesdroppers but not someone in the middle. The bundle holds AWS's RDS
certificate authorities for every region (the instance's certificate is signed by the one
named by tf `rds_ca_cert_identifier`) and Amazon's public roots, because RDS Proxy's
certificate comes from ACM; `scripts/update-rds-ca.sh` rebuilds it when AWS adds a CA.

**Backups.** Automated backups with point-in-time recovery to any second within the
retention (7 days), a final snapshot when the instance is deleted, deletion protection on.
A dev instance you mean to destroy turns protection off in `dev.tfvars`. Restores make a new
instance; step 25 practises them.

**Watching it.** RDS publishes its metrics to CloudWatch, not Prometheus, so Grafana gets a
CloudWatch data source (a read-only IAM role) and an *RDS PostgreSQL* dashboard: database
load, CPU, connections, replica lag, memory, storage, latency, IOPS. The alarms are
CloudWatch alarms, mailed through SNS (`database_alarm_email`), so they work even when the
cluster doesn't. **Database Insights** (standard mode: free, 7 days) shows what the database
spends its time on, by query and by wait; Enhanced Monitoring adds the operating system's
view every minute.

**Change data capture.** Three ways to tell the world a row changed: the application writes
and publishes (two writes, one can fail: step 13's problem); the **outbox** (the application
writes the event into the same transaction, a relay publishes it; order-service does this);
**CDC** (the database's own log is the source: Debezium reads PostgreSQL's write-ahead log
through a logical replication slot and publishes each committed change, in order, with
nothing changed in the application). CDC suits applications you don't own, like Unleash:
every insert into its audit table `events` (who changed which flag, when, before and after)
becomes a record on `flags.public.events`, kept a month there and a year in the S3 archive.
Its price: the records are the table's shape, not a designed event, and a **slot keeps every
bit of log its reader hasn't confirmed**. A stopped Debezium makes the database keep log
until the disk fills, slowly enough to be forgotten. Hence the `heartbeat.interval.ms`
(Debezium confirms its position every minute even when `events` doesn't change) and the
`replication_slot_lag` alarm (over 1 GiB held).

**Aurora instead?** Aurora PostgreSQL separates compute from a storage layer replicated six
ways across three zones: failover in about 30 seconds, up to 15 readers that share storage
(milliseconds of lag), storage billed per GB used and per I/O (or I/O-Optimized). For this
project's size, standard RDS is cheaper and teaches the same things; Aurora pays off with
heavy reads, fast failover needs, or storage that grows into terabytes.

## Where it runs

Off everywhere by default. In dev, `enable_rds = true` costs about $25 a month (Multi-AZ
db.t4g.micro, 20 GB gp3); a replica adds about $12, RDS Proxy about $22 (two vCPUs at its
minimum). Debezium runs on dev's existing Kafka Connect cluster. The lab keeps its in-cluster
PostgreSQL (with logical replication on, so it behaves the same for Debezium); RDS has no
local equivalent worth faking.

## Deploying to dev

1. **tf:** in `environments/app-cluster/dev.tfvars`, uncomment the RDS block (at least
   `enable_rds = true`, `rds_deletion_protection = false` and a final snapshot name for an
   instance you'll destroy; `database_alarm_email` to get the alarms), then plan and apply
   01-infra. Confirm the SNS e-mail. Note the outputs `rds_address`,
   `rds_master_secret_arn`, `irsa_role_arns["unleash_rds_secret"]`, `vpc_cidr_block` (and
   `rds_proxy_address` with the proxy).
2. **gitops, Unleash:** create `feature-flags/dev/unleash-rds.yaml` like
   `tests/kustomize/feature-flags-rds/unleash-rds.yaml` with those values (`host`: the
   proxy's address if you made one), and in `feature-flags/dev/kustomization.yaml` add it to
   `resources` and `../components/rds` to `components`. Merging deletes the in-cluster
   database and starts Unleash on RDS, empty: Unleash creates its tables, its admin and its
   tokens (from Secret `unleash`) on first start, so the services keep working; recreate the
   two flags as in FEATURE-FLAGS.md. The old database's volume stays until you delete it:
   `kubectl -n feature-flags delete pvc data-postgres-0`.
3. **Change data capture:** build the Kafka Connect image from the app repo (Jenkins,
   `SERVICE=kafka-connect`; it now includes Debezium) and put its tag in
   `streaming/dev/kustomization.yaml`. Then add `../components/flag-changes` to
   `streaming/dev`'s components and `../components/cdc` to `feature-flags/dev`'s; with
   Unleash on RDS also `../components/flag-changes-rds` and a
   `streaming/dev/flag-changes-rds.yaml` like
   `tests/kustomize/streaming-flag-changes-rds/flag-changes-rds.yaml` (`host`: the
   instance's address, never the proxy's). The `tests/kustomize/` overlays are exactly these
   combinations, built by `validate.sh`.

Turning it off: remove the components and files again (Unleash goes back to an empty
in-cluster database), then `enable_rds = false` and apply.

## Exercises (dev, with RDS on)

1. **Failover.** Watch Unleash (`kubectl -n feature-flags logs deploy/unleash -f`) and
   reboot with failover: `aws rds reboot-db-instance --db-instance-identifier
   microservices-dev-rds --force-failover`. Measure from the first connection error to the
   first success (the roadmap's target: under 90 seconds); `aws rds describe-events` shows
   RDS's own timeline. With RDS Proxy, repeat and compare.
2. **Rotation.** `aws secretsmanager rotate-secret --secret-id <rds_master_secret_arn>`.
   Within five minutes `kubectl -n feature-flags get secret unleash-db -o
   jsonpath='{.metadata.resourceVersion}'` changes, Reloader logs a restart, and a new
   Unleash pod starts. Count the errors in between; then do it again with the force-sync
   annotation right after rotating.
3. **A slow query.** From a pod that may reach the database (in a namespace without a
   default-deny policy), run `SELECT pg_sleep(2)` in a
   loop; find it in Database Insights' top SQL and in the PostgreSQL log in CloudWatch
   (`log_min_duration_statement`).
4. **Replica lag.** With `rds_read_replica = true`, load the primary (`pgbench`) and watch
   *Replica lag* on the dashboard.
5. **Connection pooling.** Run a Deployment of `pgbench` clients against the instance and
   scale it up until connections run out (the `connections` alarm fires); then point it at
   RDS Proxy and repeat.
6. **CDC.** Change a flag in Unleash's UI; within seconds a record with the change appears
   on `flags.public.events` (Kafka UI, or the Avro console pod's `kafka-console-consumer`).
   Stop the connector with `state: stopped` on its KafkaConnector (in Git, on a branch
   ArgoCD follows: it undoes a `kubectl edit`), change a few flags, watch
   `OldestReplicationSlotLag` grow on the dashboard, then remove the line: Debezium
   continues where it stopped, nothing lost.

## When something's wrong

| Symptom | Likely cause |
|---|---|
| Unleash crash-loops after the switch: `self-signed certificate in certificate chain` | `ca-bundle.pem` lacks the CA that signed the server's certificate (a new RDS CA: run `scripts/update-rds-ca.sh`) |
| … `Hostname/IP does not match certificate's altnames` | `host` in `unleash-rds` isn't the RDS or proxy endpoint (a CNAME of your own fails verification) |
| … `password authentication failed` | a rotation and Secret `unleash-db` not refreshed yet (force-sync) |
| ExternalSecret `unleash-db` not synced: `AccessDenied` | `secret-reader-role-arn` in `unleash-rds` isn't tf's `irsa_role_arns["unleash_rds_secret"]`, or 01-infra wasn't applied after enabling RDS |
| … timeouts | NetworkPolicy `unleash-rds`'s `vpc-cidr` wrong, or RDS's security group doesn't include the cluster's |
| Unleash didn't restart after a rotation | Reloader not running, or the Deployment lacks its annotation (only `components/rds` adds it) |
| connector `flag-changes` FAILED: `must be owner of table events` | Debezium signs in as a user that doesn't own the table and can't create the publication |
| … `permission denied to start WAL sender` / replication | the user lacks `rds_replication` (RDS) or `REPLICATION` |
| `replication_slot_lag` alarm | Debezium stopped or failing: fix it, or if it's gone for good, `SELECT pg_drop_replication_slot('flag_changes')` |
| no records on `flags.public.events` | the Connect image lacks Debezium (old tag), or `streaming/<env>` lacks the component |
