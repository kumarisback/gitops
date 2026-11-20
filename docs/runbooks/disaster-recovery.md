# Disaster recovery runbook

Roadmap step 25 (guide: `docs/BACKUP-DR.md`). Each section: when it applies, the steps,
and the time it took when it was last done. **Numbers are measured, not hoped for**: when
you run a section, write your date and time into its table.

Tools: `kubectl` and the `velero` CLI (namespace `velero`, your kubeconfig), the AWS CLI for
AWS sections. Before any restore: stop whatever would write to what you're restoring.

---

## A namespace is gone (or its data is wrong)

*Deleted by mistake, a bad migration, a corrupted volume.* Restores objects and volume data
from the newest nightly backup: up to a day of data is lost (RPO ≤ 24 h).

1. `velero backup get`: the newest `Completed` backup of `velero-daily-apps` before the
   damage. `velero backup describe <backup> --details`: its warnings must not mention a
   skipped volume.
2. If the namespace still exists with bad data, delete it: `kubectl delete namespace
   <ns> --wait`. (A restore doesn't overwrite what exists.) Pause ArgoCD's auto-sync for the
   namespace's application while you work, or it recreates empty volumes first.
3. `velero restore create --from-backup <backup> --include-namespaces <ns> --wait`
4. `velero restore describe <restore>`: phase `Completed`, no errors. Warnings about
   `kube-root-ca.crt` are expected (Kubernetes recreates it).
5. Wait for the databases (`kubectl -n <ns> rollout status statefulset/...`), check their
   data, then resume ArgoCD's sync.
6. If a database doesn't start from the copied files: restore its dump, which the backup
   hook wrote into the same volume: `mongorestore --gzip --archive=/data/db/velero-dump.archive.gz
   --drop` or `pg_restore -c -d unleash /var/lib/postgresql/data/velero-dump.pgdump`.

| Date | Where | Data | Delete | Restore → data serving | Notes |
|---|---|---|---|---|---|
| 2026-11-20 | KinD 1.37 (podman), test cluster | MongoDB 315 MB + PostgreSQL 48 MB | 16 s | **21 s** | Both databases started from the files; 500/500 tasks, 200/200 rows |

## A whole cluster is gone

*The cluster was destroyed, or is beyond repair.* The backups must be outside it: the
cloud's S3 bucket (survives), not the lab's in-cluster store (doesn't).

1. Rebuild the cluster: tf 01-infra and 02-services, then ArgoCD syncs everything from Git
   (configuration needs no restore).
2. Before Velero's first backup on the new cluster: the same repository password
   (`velero-repo-credentials`, from Secrets Manager in the cloud) and the same bucket.
3. Velero finds the existing backups (`velero backup get`, a minute after it starts).
4. For each namespace with data: as above, from step 2.

| Date | Where | Restore → data serving | Notes |
|---|---|---|---|
| — | not run yet | | Run it on dev before trusting it |

## Unleash's RDS database: back to a point in time

*Bad data written to Unleash's database.* RDS restores to any second of the last 7 days
into a **new** instance.

1. `aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier
   microservices-dev-rds --target-db-instance-identifier microservices-dev-rds-pitr
   --restore-time <UTC time before the damage> --db-subnet-group-name
   microservices-dev-rds-subnet-group --vpc-security-group-ids <the RDS security group>
   --db-parameter-group-name microservices-dev-postgres --no-publicly-accessible`
2. `aws rds wait db-instance-available --db-instance-identifier microservices-dev-rds-pitr`
3. Point Unleash at it (gitops `feature-flags/dev/unleash-rds.yaml`, `host`) or copy the
   data back with `pg_dump`/`pg_restore`; then decide what happens to the old instance.
   The new instance isn't in Terraform: import it or replace the old one deliberately.

| Date | Restore requested → available | Notes |
|---|---|---|
| — | not run yet | Roadmap: "restore to 5 minutes ago", time it |

## A volume from AWS Backup

`aws backup list-recovery-points-by-backup-vault --backup-vault-name microservices-dev-backups`,
then `aws backup start-restore-job` with the recovery point and the role
`microservices-dev-backup`; the restored EBS volume is bound to a new PVC by hand (a PV
naming its volume ID).

## Terraform state

*An apply wrote a wrong state, or the state file was damaged.*

1. Stop every pipeline that could apply.
2. `aws s3api list-object-versions --bucket <state bucket> --prefix <key>`: the version
   before the bad write.
3. Download it, check it (`terraform show <file>`), then
   `aws s3api copy-object --bucket <bucket> --key <key> --copy-source <bucket>/<key>?versionId=<id>`.
4. `terraform plan`: it should show what the bad apply changed, to fix forward.

## After any restore

- Write the time into the table above.
- Rotate what the backup contained if it may have been read: Velero backups include
  Kubernetes Secrets.
- If the monthly drill didn't catch what went wrong, make it catch it.
