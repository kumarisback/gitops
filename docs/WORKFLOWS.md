# Workflows and event-driven automation

Roadmap step 21. **Argo Workflows** runs pipelines whose every step is a container, as
pods in the cluster, described in Kubernetes objects. **Argo Events** connects them to
things that happen: a message on a Kafka topic, a file landing in S3, a schedule. Four
pieces of automation run on them here.

```
 a commit SHA ──(argo submit)──► ci-build: checkout ─► test ─► build ─► scan ─► push to ECR

 Kafka orders-dlq, users-dlq ─► EventSource dead-letters ──┐
 S3 events archive ─► SQS ─► EventSource archive-uploads ──┼─► EventBus ─► Sensors ─► dead-letter-triage
   (dev)                                                   │   (JetStream)            verify-archive-object
                                                           ┘
 every night 06:00 ─► CronWorkflow slo-report ─► yesterday's service levels
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Argo Workflows 4.1 | `addons/automation/argo-workflows.yaml`, `addons/values/*/argo-workflows.yaml` | The controller and the UI/API server (namespace `argo`); workflows, and only workflows' accounts, in `workflows` |
| Argo Events 1.9 | `addons/automation/argo-events.yaml`, `addons/values/common/argo-events.yaml` | The controller that runs event sources, sensors and the event bus |
| What runs | `automation/base` (every environment that has them), `automation/dev`; namespace `workflows` | Templates, the cron workflow, the event bus, sources, sensors, accounts, network limits |
| CI pipeline | `automation/base/ci-build.yaml` | A Spring service's Jenkins pipeline, plus tests and an image scan |
| Dead-letter triage | `automation/base/dead-letters.yaml` | A workflow per record parked in `orders-dlq` or `users-dlq`: what failed and why |
| Archive check (dev) | `automation/dev/archive-check.yaml`; tf `01-infra/workflows.tf` | Each new events-archive file is read back and checked |
| Nightly report | `automation/base/slo-report.yaml` | A WorkflowTemplate and the CronWorkflow that starts it nightly: yesterday's requests, errors and latency per API, against the SLOs |
| AWS (dev) | tf `01-infra/workflows.tf` (`enable_argo_workflows`) | Artifact bucket, the SQS queue, the workflows' IRSA roles |
| Alert | `observability/base/automation-alerts.yaml` | `ArgoWorkflowsControllerUnavailable`, tested |

## Design choices, and why

**Where.** The lab and dev, where Kafka runs (the dead-letter trigger needs it), the same
opt-in as `addons/streaming`. CI builds images once, for every environment, so it doesn't
belong in staging or production anyway; the nightly report could, once those have it.

**The CI pipeline, compared with Jenkins.** The Jenkins pipeline of a Spring service checks
out, compiles with the tests switched off (`-x test`), builds with Docker and pushes on
`main`. `ci-build` checks out the commit, **runs the tests**, builds the image, **scans it**
and pushes only if asked (`-p push=true`, dev only: the lab has no registry). The image is
built to a tarball on the run's own volume and scanned there, so nothing with a known fixable
HIGH or CRITICAL vulnerability reaches ECR; the scanner fails the run unless told to report
only. Images are built by **BuildKit rootless**: no Docker socket from the node (which would
hand the build the whole node), no privileged container; it does need seccomp and AppArmor
relaxed to make its user namespace, which the Pod Security step (27) must allow in this
namespace. Kaniko, the other usual answer, has been archived. Every parameter reaches the steps
as an environment variable rather than being pasted into a script, so a crafted value can't
run commands, and the revision must be a full commit SHA, as Jenkins insists. One run per
commit and service at a time.

**A message starts a workflow: dead letters.** `KafkaDeadLetterRecords` says records are
piling up in a dead-letter topic; nobody yet knows which, or why, without the admin pod. Each
record parked there now starts `dead-letter-triage`, which writes down its place in the
topic, the original topic, the exception notification-service recorded, the record's Avro
schema id, and the runbook's next step. Argo Events reads the topics with its own Kafka
identity (`argo-events`: read the two dead-letter topics, nothing else) and starts from the
newest record, so the first deployment doesn't triage the whole history. The record's
contents reach the workflow as data, never as code.

**A file starts a workflow: archive checks (dev).** Kafka Connect copies every event to S3
(step 13), and a backup nobody has read back isn't known to be one. S3 announces each new
file on an SQS queue; Argo Events reads the queue with its own IRSA role (no keys anywhere:
without them it uses the pod's role, as its source code shows); `verify-archive-object`
fetches the file as an input artifact and checks it: gzip that opens, a JSON object per line
with the connector's fields, values that decode, offsets that only rise and start where the
file's name says. A bad file fails the workflow, red in the UI. (S3 can't call Argo Events
directly; SQS is the queue in between, and keeps announcements for four days if the cluster
is away.)

**A schedule: the nightly report.** `slo-report` asks Prometheus for yesterday's requests,
share without server errors and share within 500 ms, per API, with the objectives beside them,
and keeps the result on the workflow for a week (`argo get`). The alerts catch a burning
budget as it happens; this is the daily record someone reads with their coffee.

**The event bus: JetStream, not Kafka.** Argo Events can use Kafka as its bus, and this
repo runs Kafka. But that bus needs its topic created by hand plus two more per sensor, each
with its grants, kept in step with every sensor added. NATS JetStream is Argo Events' own
recommendation: three small pods (the minimum it accepts), events kept up to 72 hours if no
sensor is ready.

**Who may do what.** A workflow runs its pods as a ServiceAccount of its namespace, whichever
it names. So workflows run in a namespace of their own, `workflows`, which holds only the
accounts made for them: Argo's controller and server live in `argo`, and their cluster-wide
accounts are out of a workflow's reach. Workflows run as `argo-workflow` unless they name
another; the CI pipeline as `ci-builder` (in dev: push to the services' ECR repositories,
nothing else); the archive check as `archive-checker`, the only one that reads the archive;
event sources with no Kubernetes access; sensors may only create workflows. And the
controller runs only workflows that reference a WorkflowTemplate (`templateReferencing:
Strict`): whoever may start one chooses among the templates in Git and their parameters,
not what the pods run; the CI pipeline builds only this project's repository. The UI and API
(`server`) take the caller's own Kubernetes token (`client` mode), so the server has no
account of its own to lend to whoever reaches it, and it's reached only by port-forward.
`workflow-operator` is an account for people: a short-lived token from it may see everything
in `workflows` and start, stop, retry and delete workflows, but not change templates.
Starting the CI pipeline still means building and, in dev, pushing an image: give it to
people who may do that.

**The network.** Workflows build what a commit contains, so namespace `workflows` gets two limits
(not the application's default deny: its pods fetch dependencies, scanner data and images from
the internet): no pod reaches the instance metadata service, and nothing connects to a
workflow's pods. Kafka's listener admits `workflows` among its peers (step 19).

**Artifacts.** In dev, workflows' logs and artifacts go to an S3 bucket (30 days), no keys.
Each account's workflows write under a prefix of their own (`default/`, `ci/`,
`archive-check/`), and each role may read and write only its prefix and delete nothing: a CI
build runs a commit's code, and must not read or overwrite what other workflows left. The lab
has no object store: workflows report through their results and their pods' logs, kept until
the workflow is cleaned up.

## Jenkins, Argo Workflows or GitHub Actions?

| | Jenkins | Argo Workflows | GitHub Actions |
|---|---|---|---|
| Runs | Its own server and agents (here: an EC2 instance, tf `modules/jenkins`) | Pods in the cluster, one per step | GitHub's runners, or your own |
| Pipelines are | Groovy (`Jenkinsfile`), plugins | Kubernetes objects (YAML); every step is a container | YAML in the repository |
| Scales by | Adding agents | The cluster's nodes (Karpenter) | GitHub (paid minutes) or runners you run |
| Strong at | Anything, given enough plugins; long-lived build history | Parallel and data pipelines, workflows started by cluster events, jobs near cluster resources | Repository events (pushes, pull requests), the marketplace, no infrastructure |
| Weak at | A server to patch, plugins to keep compatible, state on disk | Not a CI product: no pull-request integration, secrets and caches to set up yourself | Long or heavy jobs, reaching into a private network, cost at volume |
| Credentials | Stored in Jenkins | The workflow's own IRSA role | OIDC to AWS: short-lived, per repository (step 33) |

**When to choose which.** For building and testing on every pull request, GitHub Actions:
it lives where the code is and needs no infrastructure (step 33 moves the pipelines there).
For work that belongs to the cluster (reacting to its events, checking its data, running
batch jobs near it), Argo Workflows: it uses the cluster's identities and network and needs
no server of its own. Jenkins stays where it already runs and the investment is large;
nothing new should start there.

## Where it runs

The lab and dev. Idle, in the lab: about 0.8 GiB (two controllers, the server, three event bus
pods, an event source and a sensor; dev adds a second of each). A CI run needs about 3 GiB more while it builds (its steps
run one after another).

## Try it in the lab

Install the `argo` CLI (`brew install argo`), then `scripts/sync-local-stack.rb`.

1. **The UI.** `kubectl -n argo port-forward svc/argo-workflows-server 2746:2746`, open
   http://localhost:2746 and paste `Bearer $(kubectl create token workflow-operator -n workflows)`.
2. **The nightly report, now.** `argo submit -n workflows --from cronwf/slo-report --watch`, then
   `argo get -n workflows @latest` shows the report.
3. **A dead letter.** Send a poison record as in `docs/KAFKA.md` ("Try it", 3): in the admin
   pod, `echo 'not avro' | bin/kafka-console-producer.sh $ADMIN --topic orders`.
   notification-service parks it in `orders-dlq`, and a few seconds later
   `argo list -n workflows` shows a `dead-letter-triage` workflow; `argo get -n workflows @latest` gives
   the exception and where the record is.
4. **The CI pipeline.** For a commit pushed to GitHub:
   `argo submit -n workflows --from workflowtemplate/ci-build -p revision=$(git -C ../app rev-parse HEAD) --watch`.
   It checks out, tests, builds and scans order-service (about ten minutes the first time: no
   cache). A fixable HIGH or CRITICAL finding fails the scan step; `-p failOnVulnerabilities=false`
   reports instead.

## Deploying to dev

1. **tf:** `enable_argo_workflows = true` is in `dev.tfvars`; the apply creates the artifact
   bucket, the three IRSA roles, the queue and the archive bucket's notification (S3 sends a
   test message, which the sensor ignores).
2. **gitops:** merging installs both, and the automation in `automation/dev`. The nightly
   report runs at 06:00 India time; dead letters and archive files are checked as they come.
3. **CI:** `argo submit ... -p push=true` pushes to ECR; ECR's tags are immutable, so a commit
   already built by Jenkins fails at the push, as it would in Jenkins.
