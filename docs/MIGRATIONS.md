# Database migrations: schema changes without downtime

Roadmap step 24. A database's shape (collections, indexes, field names, the data in them)
changes with the code, so it is versioned with the code and changed by code, never by
someone typing into a production shell. Here **Flyway** applies user-service's migrations to
MongoDB, as its own step, before each release; a rename is done **expand-contract**, so the
old and new versions both work while a release rolls out or back.

```
 git push ─► image user-service:<sha>  (the service, its Migrate command, db/migration/V*.json)
                      │
 ArgoCD sync of apps/<env>
   wave -2  Secret app-secrets, ServiceAccount + NetworkPolicy for the Job
   wave -1  Job user-service-migrations ── Flyway ──► MongoDB: applies V(n+1)…, records them in
            (same image, same tag)                   flyway_schema_history
            fails? the sync stops here; the running version is untouched; DatabaseMigrationFailed
   wave  0  Deployment user-service (the new version starts on a database it can use) …
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Migrations | app `user-service/db/migration/V<n>__<what>.json` (+ `.conf`) | One MongoDB command per file, applied in order, once |
| The runner | app `user-service/.../migrations/Migrate.java`; Flyway 13.12 and its MongoDB connector | `migrate` (default), `info`, `repair`; reads `MONGO_URI`, hands the credentials to Flyway apart from the address |
| The Job | `apps/base/user-service/migrations.yaml` | The service's own image, another command; ArgoCD Sync hook in wave -1, never retried on its own |
| Network | `apps/base/network-policies.yaml` (`user-service-migrations`), `apps/local/mongodb.yaml` | The Job reaches MongoDB only (Atlas's port; the lab's MongoDB through the mesh) |
| Lint | app `src/test/.../migrations/MigrationLint*.java`; Jenkins stage *Check migrations*; Argo Workflows CI's tests | Names and numbering, one command per file, destructive commands only in a `contract_` migration, index builds outside transactions |
| Alert | `observability/base/migration-alerts.yaml` | `DatabaseMigrationFailed`, tested |

## Design choices, and why

**Where migrations run.** Four common places, each with a catch:

| Where | Good | The catch |
|---|---|---|
| The service at startup (Spring Boot's Flyway integration) | Nothing extra to run | Every replica tries at once; a slow migration fails startup probes; the service's identity needs schema rights |
| An init container | Runs before the service, same pod | Same race (one per pod), and on every pod restart |
| A CI step | Runs once, before deploy | CI then needs network access and credentials for every environment's database |
| **A Job run by ArgoCD before the rollout** (this) | Once per sync, inside the environment, with its own identity and policy; a failure stops the release | ArgoCD runs it on every sync, so migrations must be idempotent (Flyway's history makes them so) |

Flyway can't lock its history collection in MongoDB, so two runs at once could both apply a
migration. One Job per sync, and ArgoCD syncs an application one operation at a time,
prevents that; the service never runs migrations itself.

**PreSync or Sync?** The roadmap says PreSync hook. PreSync runs before anything in the sync
is applied, including this Job's own NetworkPolicy and ServiceAccount: the first time, the
namespace's default-deny would cut it off from the database. As a Sync hook in wave -1, with
its policy, account and the app Secret in wave -2, ArgoCD applies those, runs the Job, waits
for it, and only then applies wave 0 (the Deployment). Same guarantee, no chicken-and-egg.

**Same image, same tag.** The migrations a version needs are files in that version's image
(`/app/db/migration`), run by a small `Migrate` command in it (no Spring context, no tracing
agent). The Job names the service's image, so each environment's tag applies to both: the
Job can't run migrations from another version than the pods that follow. A separate
migrations image would need its own repository, build and tag, all kept in step by hand.

**JSON migrations, one command each.** Flyway's MongoDB connector runs JSON migrations
through the driver, each in a transaction (the lab's MongoDB is a replica set since step 13,
Atlas always is), or JavaScript ones through `mongosh`, without. JSON was chosen: no shell in
the image, and transactions where MongoDB allows them. Where it doesn't (building an index
on an existing collection: error 263, *OperationNotSupportedInTransaction*), the migration's
`<file>.conf` says `executeInTransaction=false`, and the lint insists on it.

**Existing databases.** The lab's and dev's databases had data before they had migrations.
Flyway refuses a non-empty database without history unless told otherwise; `Migrate` starts
such a history at version 0 (`baselineOnMigrate`, `baselineVersion 0`), so V1 onwards still
run on it.

**Applied migrations are history.** A migration's checksum is recorded when it runs; one
edited afterwards fails validation and stops the release. To change what a migration did,
write the next one.

## Expand-contract: renaming a field without downtime

During a rollout (and after a rollback) two versions of user-service run against one
database. So a breaking change is split into steps that each version in play can live with:
**expand** (add the new shape beside the old), **migrate** (backfill), **switch** (read the
new), **contract** (stop writing the old, then remove it), each a separate release.

The rename here: tasks' stored field `description` becomes `details`. The API keeps calling
it `description`: what's stored and what's exposed are separate contracts, changed
separately.

| Release | Code | Migration | Safe to roll back to the previous release because… |
|---|---|---|---|
| **1. Expand** (this step) | writes `details` *and* `description`; reads `details`, falls back to `description` | V2: copy `description` into `details` where missing | the previous version reads only `description`, still written |
| 2. Switch | reads only `details`; still writes both | none | release 1 reads `details` too, and `description` is still written |
| 3. Contract (code) | writes only `details` | none | release 2 reads only `details` |
| 4. Contract (data) | — | `V<n>__contract_tasks_description.json`: `$unset` `description` | release 3 doesn't know `description` exists |

Release 1 is in the code now (`Task.java`, migration V2). Releases 2–4 are the exercise
below: each must be deployed, and running everywhere, before the next is merged. Merged
together, the data contraction would run while pods of the expand version still read
`description`.

**Locking, in MongoDB terms.** There is no `ALTER TABLE` lock, but there are equivalents:
an index build holds an exclusive lock briefly at its start and end and loads the primary
meanwhile (build big ones off-peak); `collMod` with a validator can start rejecting the
running version's writes (hence: contract migrations only); a backfill over millions of
documents is one long write that fills the oplog and lags replicas (batch it, or backfill
from the application as documents are read). The lint blocks the destructive ones outside a
`contract_` migration.

## When a migration fails

In a transaction, nothing changed: fix the migration (it never ran successfully, so it may
be changed) and release again. Outside one (an index build, for example) it may have done
part of its work, and Flyway records it as failed and refuses to go on:

```
Detected failed migration to version 3
```

1. Find out what it did: `kubectl -n <namespace> logs job/user-service-migrations`, and
   look at the database.
2. Undo or finish its half-done changes by hand (for a failed unique index: remove the
   duplicates; the index itself isn't left behind).
3. Forget the failure, then release again: run the same Job with `args: [repair]`
   (or locally: `MONGO_URI=… MIGRATIONS_LOCATION=filesystem:db/migration java
   -Dloader.main=com.example.demo.migrations.Migrate -cp build/libs/demo-0.0.1-SNAPSHOT.jar
   org.springframework.boot.loader.launch.PropertiesLauncher repair`).

`info` lists every migration and its state the same way.

## Try it in the lab

After `scripts/build-and-push.sh` (or the podman scripts) and a sync:

1. **It ran.** `kubectl -n development logs job/user-service-migrations`: `Migrations:
   schema 0 -> 2, 2 applied` the first time, `unchanged` after. In MongoDB
   (`kubectl -n development exec -it mongodb-0 -- mongosh microservices`):
   `db.flyway_schema_history.find()`, `db.tasks.getIndexes()`, and tasks now carrying both
   `description` and `details`.
2. **Zero downtime, measured.** In one terminal, a loop that creates and lists tasks through
   Kong every 0.2 s and prints any non-2xx; in another, deploy each expand-contract release
   in turn. No errors at any stage, including a rollback (`git revert` the release's
   commit in gitops) between 1 and 2.
3. **A migration that fails halfway.** Add `V3__users_unique_username.json` (a unique index
   on `users.username`, with its `.conf`), create two users with the same name directly in
   MongoDB, release: the Job fails, `DatabaseMigrationFailed` fires, the old version keeps
   serving. Recover as above.
4. **The lint.** Add a migration with `{"drop": "tasks"}`: `./gradlew test` fails in
   `MigrationLintTest` (and so would Jenkins' *Check migrations* stage) before anything
   reaches a database.
5. **Rollback with a forward-compatible schema.** After release 1, roll back the
   application (previous image tag) without touching the database: the older version works,
   because release 1 kept writing what it reads.
