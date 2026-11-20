# Backups and disaster recovery: backups you've actually restored

Roadmap step 25. A backup is worth exactly what a restore from it gives back, so this step
is built around restores: measured once by hand (the numbers below are real), and repeated
automatically every month. What is backed up, where, for how long, and how fast it comes
back are decided per component, with **RPO** (how much data a loss may cost) and **RTO**
(how long until it works again) as the measure.

```
 nightly 02:00                                             the 1st of each month 05:00
 Velero schedule velero-daily-apps ──► bucket (S3 / lab: SeaweedFS) ◄── restore drill (Argo CronWorkflow):
   namespaces development, feature-flags     │                         newest backup → scratch namespaces,
   objects + volume data (Kopia, encrypted)  │                         workloads at 0 replicas, checked, deleted
   hooks: mongodump / pg_dump first          │
                                             ▼  disaster: delete namespace → Restore → measured RTO
 AWS Backup (tf enable_aws_backup): RDS, EBS gp3-retain, EFS tagged Backup=daily → vault (lockable, copyable)
 Terraform state: versioned buckets (tf shared-services) · RDS: its own PITR (step 23) · MongoDB Atlas: Atlas's backups
```

## RPO and RTO, per component

| Component | What protects it | RPO | RTO (measured or expected) |
|---|---|---|---|
| Lab MongoDB, Unleash's PostgreSQL (in-cluster) | Velero nightly (file copy + dump), kept 7 days | ≤ 24 h | **21 s** to restore both namespaces and serve data (lab, measured, ~360 MB) |
| Kubernetes configuration | Git (ArgoCD resyncs); Velero as a second copy | 0 (Git) | minutes: a sync |
| Unleash on RDS (step 23) | RDS automated backups with point-in-time recovery (7 days); AWS Backup daily/monthly when on | ~5 min (PITR) | new instance: expect 10–20 min (measure: runbook) |
| MongoDB Atlas (dev's services) | Atlas's own cloud backups | Atlas plan's | Atlas restore (outside this repo) |
| EBS volumes with no other copy (`gp3-retain`) | Velero (CSI snapshot, data moved to S3); AWS Backup when on | ≤ 24 h | expect minutes per volume (measure: runbook) |
| Kafka | its own replicas (3 brokers, min ISR 2); events archived to S3 (step 13) | replication: 0 | brokers rebuild from replicas; not restored from backup |
| Terraform state | S3 versioning, older versions 90 days, newest 20 always | per apply | minutes: restore the previous version |

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Velero 1.18.2 (chart 12.2.5), AWS plugin 1.14.4 | `addons/backup/velero.yaml`, `addons/values/*/velero.yaml` | Nightly backup of `development` and `feature-flags` (objects and volume data), kept a week; restores |
| Its bucket and role | tf 01-infra `backup.tf` (`enable_velero`, on in dev) | Versioned S3 bucket (deleted backups recoverable 14 days), encrypted, private; IRSA role limited to it |
| The lab's store | `backup/local` (SeaweedFS 4.54, namespace `backup-store`) | S3 for Velero in KinD, only Velero may reach it; keys from `scripts/start-lab.sh` |
| Repository password | dev: `backup/dev` ExternalSecret ← tf `set-secret.sh dev velero-repository`; lab: `start-lab.sh` | Encrypts the volume data Velero keeps |
| Database hooks | `apps/local/mongodb.yaml`, `feature-flags/base/postgres.yaml` | A consistent dump into the volume just before it is copied |
| Volumes in the cloud | `platform/storage/volumesnapshotclass.yaml` (labelled for Velero) | CSI snapshot, then the data moved to the bucket |
| AWS Backup | tf `modules/backup`, 01-infra (`enable_aws_backup`, off) | RDS, EBS and EFS tagged `Backup=daily`: daily (35 days) and monthly (a year), optional vault lock and cross-region copy, SNS for failures |
| State buckets | tf `modules/state-bucket`, shared-services | Versioning, bounded history, encryption, no public access |
| Monthly drill | `automation/base/restore-drill.yaml`, `backup/base` | Restores the newest backup into scratch namespaces, checks it, deletes them |
| Alerts | `observability/base/backup-alerts.yaml` | `BackupTooOld`, `BackupFailed`, `RestoreDrillFailing`, tested |
| Runbook | `docs/runbooks/disaster-recovery.md` | Each kind of loss, step by step, with measured times |

## Design choices, and why

**An untested backup is not a backup.** The deliverable is the restore. The full drill
(delete the namespaces, restore, time it) was run before this was committed, on a KinD
cluster with these exact values; it found three problems that a backup job alone would
never have shown (below). The monthly drill keeps checking that the newest backup is
complete and readable; the runbook's full drill measures the RTO again.

**What a "Completed" backup can hide.** The first test backup reported *Completed*, with two
warnings, and contained no database data: KinD's local-path provisioner makes `hostPath`
volumes, and Velero's file-system backup skips those. The lab's storage classes now make
`local` volumes (an annotation, `defaultVolumeType: local`), which Velero copies. Volumes
made before stay `hostPath` until recreated: in an existing lab, dump the databases,
delete their StatefulSets and PVCs, let ArgoCD recreate them, and restore the dumps (or
recreate the lab). The lesson stands for any tool: read the warnings, and count what came
back.

**Two ways to copy a volume.** In EKS, Velero takes a CSI snapshot (EBS CSI driver,
`ebs-snapshot` class) and its node agent moves the snapshot's data to the bucket
(`snapshotMoveData`), so a backup survives its volume, zone and cluster; a bare EBS snapshot
would stay in the same account and region and die with a careless cleanup. In KinD there
are no snapshots: the node agent copies the files (file-system backup). Either way the data
lands in Kopia repositories in the bucket, deduplicated and encrypted with the repository
password.

**Consistency.** A volume copied file by file while a database writes to it isn't a
consistent database. Before Velero copies them, a hook dumps each database into its own
volume (`mongodump`, `pg_dump`): the dump is consistent, and travels with the files. In the
measured drill, both databases started from the copied files; the dumps are the fallback.
MongoDB's `fsyncLock` would make the files consistent too, but a failed unlock would leave
the database refusing writes. CSI snapshots in the cloud are point-in-time (crash-
consistent), which both databases recover from.

**The repository password.** Without a `velero-repo-credentials` Secret, Velero creates one
with a password that is the same in every installation: the "encryption" of every backup
would be public. Here it is generated (dev: Secrets Manager via `set-secret.sh`, which
refuses to replace it; lab: `start-lab.sh`). Losing it loses every backup made with it:
keep a copy outside the cluster and the account.

**What isn't backed up, on purpose.** Kafka: copied files of running brokers aren't a
consistent Kafka; it keeps three replicas, and events go to the S3 archive. Configuration:
Git is its backup, ArgoCD its restore. Monitoring data: lost with the cluster, rebuilt.
MongoDB Atlas: Atlas's backups, configured in Atlas.

**AWS Backup on top of Velero and RDS's own backups.** Those live beside what they protect.
A backup vault is separate, can be **locked** (governance mode: removable by someone with
the permission; compliance mode: nobody, not even the account's root, can delete a recovery
point early, forever, after a grace period: ransomware protection, and irreversible), and
can **copy** every recovery point to another region or account. Off by default: it bills for
what it keeps, and compliance mode is a decision, not a default.

**Immutability, in order of strength.** Bucket versioning (Velero's bucket: deleted backups
come back for 14 days; state buckets: 90 days); vault lock in governance mode; vault lock in
compliance mode; copies into a separate account whose credentials the cluster never holds.
S3 Object Lock on Velero's bucket would fight Velero's own expiry; learning topic 25 says
how to combine them.

**Terraform state.** The state buckets were made by hand before Terraform ran. Versioning was
the finding to check; shared-services now manages it (and a bounded history, encryption,
no public access) for all of them. A bad apply's state is restored from the previous
version (runbook). MFA delete can only be turned on by the account's root user, by hand.

## Where it runs

Velero in the lab and dev (with tf `enable_velero`, on in `dev.tfvars`); staging and prod opt
in like other add-on groups. AWS Backup wherever `enable_aws_backup` is set. The lab's store
lives in the cluster it backs up: fine for practice, useless for losing the cluster; the
runbook's "new cluster" drill puts it outside.

## Try it in the lab

After `scripts/start-lab.sh` (it generates `apps/local/backup.env`) and a sync, with the
Velero CLI pointed at the cluster (`velero` reads your kubeconfig; namespace `velero`):

1. `velero backup create test --from-schedule velero-daily-apps --wait`, then
   `velero backup describe test --details`: read the warnings; every database volume must be
   listed under pod volume backups.
2. The full drill: `docs/runbooks/disaster-recovery.md`, "a namespace is gone". Time it and
   write your number next to the one above.
3. The monthly drill now: `argo submit -n workflows --from cronwf/restore-drill`, then
   `argo get -n workflows @latest`: the restore's name, items, warnings and times.
4. Break it: delete `velero-repo-credentials`' value in a scratch cluster and restore. What
   does Velero say, and why is that the right failure?
