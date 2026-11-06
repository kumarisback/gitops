# A service mesh: identity and policy between the services

Roadmap step 18. Kong (steps 16–17) decides what may come **in** from outside: north-south
traffic. Between the services (east-west) everything could still call everything, in plain
text, and a service knew its caller only by IP address. A **service mesh** gives every
workload a cryptographic identity, encrypts and authenticates every connection between them
(mutual TLS), and lets policies say who may call what, without a line of application code.

```
ALB / Traefik ─► Kong ─┐                                   Prometheus ──mTLS──► pods (scrapes)
                       │ mTLS (HBONE)                       blackbox  ─┐
user-service ──────────┼──────────► waypoint ──mTLS──► order-service   │
order-service ─────────┘   who may call what, retries ──► user-service ◄┘
                                                      └─► frontend
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Istio 1.31 (ambient mode) | `addons/applications/{istio-base,istiod,istio-cni,ztunnel}.yaml`, `addons/values/*/` | istiod issues identities and turns policies into configuration; ztunnel (one per node) does mutual TLS and connection-level policy; the CNI agent moves meshed pods' traffic through ztunnel. Every environment |
| Who is in the mesh | `apps/*/namespace.yaml` (the app namespace), pod labels for Kong's gateways, Prometheus and the blackbox exporter | Everything that talks to the services |
| Strict mutual TLS | `apps/base/mesh.yaml`, PeerAuthentication | Plain text into the app namespace is refused |
| The waypoint | `apps/base/mesh.yaml`, Gateway `waypoint` | One Envoy proxy (two in the cloud) that requests to the namespace's Services pass through: HTTP-level policy, retries, timeouts, metrics |
| Policies | `apps/base/mesh.yaml`, `apps/local/mongodb.yaml` | Who may connect to each pod, who may call which paths of each Service |
| Retries and timeouts | `apps/base/mesh.yaml`, VirtualServices | Safe retries and a deadline for the two APIs |
| Monitoring | `platform/mesh` (PodMonitors), `observability/base/mesh-alerts.yaml` | istiod, ztunnel and waypoint metrics; 3 tested alerts |

## Design choices, and why

**Ambient, not sidecars.** The classic mesh adds a proxy container to every pod: 50–100 MB of
memory each, a restart to join, and two proxies on every hop. Istio's ambient mode splits the
work: **ztunnel**, one per node, gives each pod its identity and encrypts its connections
(layer 4); a **waypoint** per namespace handles HTTP (layer 7), and only for namespaces that
need it. Here: three ztunnels and one or two waypoints instead of a sidecar in every pod, and
pods join the mesh by a label, without restarting.

**Istio, not Linkerd.** Linkerd is the simpler mesh (a small Rust proxy, excellent defaults,
far fewer concepts), and the roadmap suggests starting with it. Two things decided against it
here: since 2024 Linkerd's project publishes only weekly edge builds in the open (stable
releases need a Buoyant licence for companies above 50 people), and its identities hang off a
trust anchor certificate you issue and rotate yourself (cert-manager, which this repo doesn't
have yet). Istio is CNCF-graduated, has a sidecar-free mode that is generally available, speaks
the Gateway API natively, and runs its own certificate authority. The price is that Istio is
bigger and has more ways to be configured wrongly.

**Two layers of policy.** Each pod's ztunnel lets in only two identities: the namespace's
waypoint, through which every request to a Service comes, and Prometheus, which scrapes pods
directly, and only on port 8081. For that the services serve actuator (health checks and
metrics) on a port of its own (`management.server.port`); before, it shared the API's port and
path, so the gateway exposed it to anyone and Prometheus couldn't be let in without also being
able to call the API. The waypoint then decides per request:

| Service | May be called by |
|---|---|
| frontend | Kong (everything); the synthetic checks (`GET /`) |
| user-service | Kong (everything); order-service (`GET /api/auth/jwks.json` only); the synthetic checks (`POST /api/auth/signin`) |
| order-service | Kong (everything); user-service (`GET /api/orders/user/*` only); the synthetic checks (`GET /api/orders/status`) |
| notification-service | nobody (it only consumes from Kafka) |
| MongoDB (lab) | user-service, order-service, its init Job |

A compromised order-service can fetch user-service's public key and nothing else from it;
before this step it could call any endpoint of any service.

**Identities.** A ServiceAccount is the identity: `cluster.local/ns/kong/sa/kong-gateway` is
Kong's gateways. Callers in the application's own namespace are written `*/sa/<name>` together
with `namespaces: [development]`, and both must match: the namespace differs per environment
(development, staging, production), so each overlay (`apps/<env>/kustomization.yaml`) fills in
its own with a Kustomize replacement. A ServiceAccount of the same name in any other namespace
doesn't match.

**Kong through the waypoint.** Kong normally sends requests straight to a pod's address,
which would skip the waypoint and its rules. The `ingress.kubernetes.io/service-upstream`
annotation on each Service makes it use the Service's address instead.

**Retries that can't double an order.** The waypoint retries a request at most twice, and
only when it certainly never reached the service: the connection failed, was refused, or was
reset before the request was sent. Retrying after a 503 or a timeout could create an order
twice, so those go back to the caller. Every call has a 10-second deadline.

**What joining the mesh changed elsewhere.** Kong's gateways, Prometheus and the blackbox
exporter are in the mesh, because the services now refuse plain text. Traffic between two
meshed pods arrives on port 15008 (HBONE), so two NetworkPolicies allow that port from
Prometheus; and in ambient mode the kubelet's health checks come from `169.254.7.127`, which
the blackbox exporter's policy now lets in. Exercises that ran a pod of their own inside the
namespace now go through Kong.

**Kong's admin port and the mesh.** A NetworkPolicy sees mesh traffic only as port 15008; the
port inside the tunnel is invisible to it. So letting Prometheus reach Kong's gateways over the
mesh would have let it reach their admin API too, which in DB-less mode replaces the whole
configuration. An Istio policy on the gateways (`platform/kong/mesh-policy.yaml`) refuses every
mesh identity on the admin port; the controller, outside the mesh, still reaches it.

**Not done here.** *Traffic splitting* needs two versions of a service; Argo Rollouts does
weighted canaries with the mesh in step 20. *The schema registry's admin API* (open since
step 13) is in the `kafka` namespace, which isn't in the mesh: putting Strimzi's brokers into
it is a project of its own, and the registry's own authentication (step 30) is the better fix.

**Rolling it out for real.** Merging all of this at once makes the services refuse plain text
before Kong's and Prometheus's pods have restarted into the mesh: a minute or two of refused
requests in dev. In production you'd do it in two changes: first everything with
`mode: PERMISSIVE` (both accepted), check that the waypoint's metrics show only mTLS, then
`STRICT`.

## Is a mesh worth it?

For four services, honestly no. Kong already checks who comes in, each service verifies
tokens itself, and NetworkPolicies (step 19) can say which pods may talk. What only a mesh
gives: encryption and authentication of every internal call without touching code, which
compliance regimes ask for; policies by identity rather than IP address, which survive pods
moving; and the same request metrics for every service, whatever its language. It earns its
keep with many services and teams, a requirement for encryption in transit, or a zero-trust
mandate. Ambient mode lowers the price enough that the threshold is now lower than it was.

## Where it runs

Every environment. In the lab it costs about 0.8 GiB (istiod, a ztunnel and CNI agent per
node, one waypoint).

## Try it in the lab

After `scripts/sync-local-stack.rb`:

1. **Who is in the mesh.** `kubectl get pods -n istio-system` (istiod, ztunnel and istio-cni
   per node); `kubectl get gateway waypoint -n development` (Programmed);
   `kubectl logs -n istio-system -l app=ztunnel --tail=20` shows connections with the
   identity at each end (`src.identity=spiffe://cluster.local/ns/kong/sa/kong-gateway`).
2. **What the policies refuse.** order-service may fetch user-service's key and nothing else
from it:

   ```bash
   kubectl exec -n development deploy/order-service -- wget -qO- http://user-service/api/auth/jwks.json   # allowed
   kubectl exec -n development deploy/order-service -- wget -qO- http://user-service/api/tasks           # 403, "RBAC: access denied"
   ```

   A pod of your own in the namespace would be in the mesh with an identity no policy names,
   but since step 19 it gets no further than DNS: the namespace's NetworkPolicies drop its
   connections before the mesh sees them (`docs/NETWORK-POLICIES.md`).

3. **Golden signals without instrumentation.** In Grafana → Explore → Prometheus:
   `sum by (source_workload, destination_workload, response_code) (rate(istio_requests_total{reporter="waypoint"}[5m]))`:
   who calls whom, how often, with what result, for every service, measured by the waypoint.
4. **A timeout at work.** Make user-service slow for order-service with a fault (a
   VirtualService of your own, `fault.delay` 12s for `/api/auth/jwks.json`) and watch the
   waypoint give up after 10 seconds with a 504. Delete it afterwards.

## Deploying to dev

Merging gitops installs Istio, labels the namespace, restarts Kong's, Prometheus's and the
blackbox exporter's pods into the mesh and applies the policies (see "Rolling it out for
real" for the short gap). Nothing in Terraform or the app changes. If something is refused
that shouldn't be: `docs/runbooks.md`, "Service mesh".
