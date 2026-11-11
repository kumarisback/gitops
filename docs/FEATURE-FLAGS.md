# Feature flags: deploying is not releasing

Roadmap step 22. A deploy puts new code on the servers; a **release** puts a feature in front
of users. Feature flags separate the two: the code ships switched off, and a person turns it
on (for some users, a share of them, or everyone) without another deploy, and off again in
seconds. Here **Unleash** (open source, self-hosted) holds the flags; the frontend and
order-service ask it.

```
                        ┌─ browser ─► Kong /flags/api/frontend ─► Unleash ─► PostgreSQL
 frontend (task summary)┘   (frontend token, public)                  ▲
                                                                       │ client API (backend token)
 order-service (kill switch around order events) ──────────────────────┘
 people ─► kubectl port-forward ─► Unleash UI (/flags): flags, strategies, audit log
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Unleash 8.3 and PostgreSQL 17 | `feature-flags/base` (namespace `feature-flags`), `addons/feature-flags` | The flag service and its store. The lab and dev |
| Secrets | `feature-flags/dev`, `apps/dev/unleash-tokens.yaml` (from Secrets Manager); `scripts/start-lab.sh` in the lab; tf `set-secret.sh <env> unleash` | Database and admin passwords, the backend token (order-service), the frontend token (browsers) |
| The browser's way in | `feature-flags/base/route.yaml`; Kong's Gateway admits routes from `feature-flags` | Only the frontend API, `/flags/api/frontend`; the UI and admin API are port-forward only |
| Frontend flag | app `frontend`: `src/lib/flags.js`, `FlagContext.jsx`; runtime config at `/config/runtime-config.json` | `dashboard-task-summary`: a summary of tasks by state, shown to whom the flag says |
| Kill switch | app `order-service`: `flags/`, `OutboxRelay` | `order-events-publishing`: off holds order events in the outbox |
| Network | `feature-flags/base/network-policy.yaml`; Kong's and order-service's egress | Unleash takes Kong, order-service and Prometheus; its database takes Unleash only |
| Alert | `observability/base/feature-flag-alerts.yaml` | `FeatureFlagServiceUnavailable`, tested |

## Design choices, and why

**Kinds of flag, and why it matters.** Unleash names four, with different lifetimes:
*release* flags (a feature on its way out; removed within weeks), *experiment* flags (an A/B
test; removed when it's decided), *operational* flags and *kill switches* (a way to turn
something off under load or failure; permanent), and *permission* flags (a feature for some
customers; long-lived). Each kind wants a different default and a different fate.
`dashboard-task-summary` is a release flag; `order-events-publishing` is a kill switch.

**What happens when Unleash can't answer.** Every check names a fallback, and the fallback
is chosen for safety, not convenience. The kill switch's is *on*: a flag service that's down
must never stop the business. The task summary's is *off*: an unreleased feature stays
unreleased. Both SDKs fetch in the background and answer from memory, so a check never waits
on the network; they keep the last answers while Unleash is away, and a pod started meanwhile
uses the fallbacks. Without Unleash at all (staging and production for now) the frontend's
flag client never starts and order-service uses the fallbacks.

**The kill switch around Kafka.** Turned off, order-service stops publishing order events
and leaves them in its outbox (step 13), where they wait in order; turned back on, they go
out. Orders are still taken: what stops is only their announcement to the rest of the system,
for instance while a consumer is broken or Kafka is being repaired. Unlike scaling to zero or
a rollback, nothing is lost and nothing redeploys. A pause long enough fires
`OutboxBacklogGrowing`, as it should: someone must turn it back on.

**Tokens, and which are secret.** The *backend token* lets order-service read every flag's
rules for an environment: secret, from Secrets Manager (dev) or a git-ignored file (lab). The
*frontend token* only lets a browser ask which flags are on for its user: public by design,
since every browser receives it, but still not baked into the image. The cluster serves it
at `/config/runtime-config.json`, so one frontend image runs in every environment. Unleash
creates both tokens on its first start from those values. Its admin password is set the same
way; the default (`unleash4all`) never exists here.

**What reaches Unleash.** Browsers reach only the frontend API, through Kong; the UI and the
admin API (which change flags) are reached by port-forward, with a person's own Kubernetes
access and the admin password. In namespace `feature-flags` everything is denied by
default (step 19), then: Kong's gateways, order-service and Prometheus may reach Unleash, and
only Unleash its database. Unleash's calls home (version check, telemetry) are off.

**Flag debt.** Every flag is a branch in the code, tested less with every week it lives.
The rule here: a release flag is removed within two weeks of reaching 100%: delete the check
and the code for the old path, then archive the flag in Unleash. Unleash marks flags past
their kind's expected lifetime as potentially stale; look at that list when planning. A kill
switch stays, and is exercised: flip it in dev now and then, to know it still works.

**Unleash, Flagsmith, LaunchDarkly or flagd.** Unleash's open-source edition runs anywhere
with one PostgreSQL, has gradual rollouts, targeting, an audit log and SDKs for everything; it
caps the open edition at one project and two environments, and its frontend API isn't meant
to scale out (Unleash Edge, the scaling layer, reaches the end of its open-source support at
the end of 2026; after that it's part of the paid edition). Flagsmith is similar,
also self-hostable. LaunchDarkly is the SaaS leader: the most capable, nothing to run, paid per
seat and usage. OpenFeature's flagd keeps flags in Git as configuration: GitOps-native and
without a database or UI, but a flag change is a commit, not a click. A team that may switch
later codes against OpenFeature's API, with a provider for whichever service it uses.

**Flags and Argo Rollouts together.** They answer different questions. A canary (step 20)
asks *is this build healthy?*, with real traffic and automatic rollback, but it releases
whatever the build contains to whoever its share is. A flag asks *who should see this
feature?*, per user and reversible in seconds, but it can't catch a build that crashes. Used
together: the code ships through the canary with its flag off (dark), so only its health is
at stake; then the flag releases the feature gradually, 10%, 50%, everyone, and a problem
with the *feature* is a click, not a rollback. The task summary went exactly this way: the
frontend's blue/green release put it on the servers, the flag decides who sees it.

## Where it runs

The lab and dev, each with its own Unleash: about 0.4 GiB (Unleash and PostgreSQL). A
company would run one Unleash for every environment (OSS: development and production; more
need Enterprise); with a cluster per environment here, each has its own.

## Try it in the lab

After `scripts/start-lab.sh` (it makes Unleash's secrets) and `scripts/sync-local-stack.rb`:

1. **The UI.** `kubectl -n feature-flags port-forward svc/unleash 4242:4242`, open
   http://localhost:4242/flags, sign in as `admin` with `ADMIN_PASSWORD` from
   `apps/local/unleash.env`.
2. **Create the two flags** in project Default: `order-events-publishing` (type *Kill
   switch*) and `dashboard-task-summary` (type *Release*). Enable each in *development* with the
   standard (on for everyone) strategy for the first; leave the second off for now.
3. **Release the summary gradually.** On `dashboard-task-summary`, add a *Gradual rollout*
   strategy at 50% with stickiness `userId`, enable it, and sign in as a few different users:
   about half see "Pending / In progress / Completed" above their tasks, and each keeps the
   same answer every time. Then add a constraint `userId` *in* your own user's id to target
   yourself; then 100%.
4. **The kill switch.** Turn `order-events-publishing` off, create an order, and watch: no
   new record on topic `orders` (Kafka UI), `order_events_publishing` 0 in Prometheus, the
   order waiting in the outbox (`outbox_pending` 1). Turn it on: within ten seconds the event
   goes out and notification-service sends its notification. No pod restarted.
5. **The audit log.** Each flag's *Event log* shows who changed what and when.

## Deploying to dev

1. **tf:** the apply creates the empty secret `microservices/dev/unleash`; then
   `./scripts/set-secret.sh dev unleash` fills it (before Unleash's first start: PostgreSQL
   takes its password, and Unleash makes its tokens, only then).
2. **gitops:** merging installs Unleash and PostgreSQL, the routes and policies, and the
   services' secrets; order-service and the frontend restart with their flag settings.
3. **Create the flags** as in the lab. Until then, both checks take their fallbacks: events
   keep flowing, the summary stays hidden.
