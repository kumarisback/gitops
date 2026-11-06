# Kong: an API gateway behind the edge

Roadmap step 16. Until now one Ingress told the edge (the ALB in the cloud, Traefik in the
lab) which path goes to which service. That is an **ingress controller's** job: get HTTP into
the cluster. An **API gateway** does more with each request: authentication, rate limits per
client, API keys, header and path changes, versioned APIs, per-route metrics. This step puts
Kong in the path and moves the routing to the **Gateway API**; step 17 uses Kong for what a
gateway is for (plugins).

```
browser ─► edge: ALB (cloud) / Traefik (lab) ─► Kong gateway ─┬─► frontend          /
             TLS (step 03), the public address    routes,      ├─► user-service      /api
                                                  plugins      └─► order-service     /api/orders, /api/v1/orders

Kong Ingress Controller: watches HTTPRoutes, the Gateway, plugins ─► pushes Kong's configuration to each gateway pod
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Gateway API CRDs v1.3.0 | `platform/gateway-api` (release file, pinned by checksum), Application `gateway-api` | `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant` |
| Kong 3.9 + Kong Ingress Controller 3.5 | `addons/applications/kong.yaml`, `addons/values/{common,cloud,local}/kong.yaml` | The gateway (DB-less, open source) and the controller that configures it; in every environment |
| The edge's Ingress | `addons/values/cloud/kong.yaml` (ALB), `addons/values/local/kong.yaml` (Traefik) | Everything from the edge to Kong; replaces the services' old `app-ingress` |
| GatewayClass and Gateway | `platform/kong/gateway.yaml`, Application `kong-config` | What routes attach to: HTTP on port 80, from the application namespaces only |
| Routes | `apps/base/routes.yaml` | One `HTTPRoute` per service, owned next to the services |
| Plugins | `platform/kong/plugins.yaml`, `apps/base/kong.yaml` | Metrics and security headers everywhere; sign-in limits, token checks, partner keys and tiers where routes name them (step 17) |
| Rate-limit counters | `platform/kong/redis.yaml` | Valkey, shared by every gateway pod, reachable only from them |
| Admin API protection | `platform/kong/network-policy.yaml` | Only the controller may reach Kong's admin API |
| Observability | `observability/base/gateway-alerts.yaml`, `dashboards/kong.json`; Alloy | 3 tested alerts, the **Kong gateway** dashboard, Kong's access lines as `log_type="gateway"` |

## Design choices, and why

**Behind the edge, not instead of it.** The ALB stays the public entrance: AWS runs it, it
spans the zones, and it is where TLS with an ACM certificate (and a WAF, later) belongs. Kong,
inside the cluster, does the per-request API logic and is configured from Git. The price is one
more hop, a millisecond or two, which the dashboard's "where the time goes" panel shows. The lab
mirrors it with Traefik in front, so both have the same shape.

**DB-less, configured by the controller.** Kong can keep its configuration in PostgreSQL and be
changed through its admin API. Here it has no database: the controller translates Kubernetes
resources into one declarative configuration and pushes it to every gateway pod. Git is the
only source of truth, a new pod gets the full configuration on start, and nothing can drift.
The cost: no admin-API changes by hand (which is the point), and plugins that need shared state
(rate-limit counters) need Redis instead of a database (step 17).

**Gateway API instead of Ingress.** The same three routes, two ways:

| | Ingress (as before) | Gateway API (now) |
|---|---|---|
| Who owns what | One object, everything in it | The platform owns `GatewayClass` and `Gateway` (`platform/kong`); each team owns its `HTTPRoute`s |
| Which rule wins | The order you write them in (the old Ingress needed `/api/orders` before `/api`) | The longest matching path, always |
| Across namespaces | An Ingress reaches Services in its own namespace only | Routes in `development` attach to a Gateway in `kong`, if its `allowedRoutes` lets them |
| Rewrites, headers, splits, mirrors | Controller-specific annotations (`konghq.com/strip-path`, ...) | Standard filters and weights in the spec, the same with any implementation |
| Did it work? | Little feedback | Each route reports `Accepted` and `ResolvedRefs` in its status |

For comparison, the old routing as an Ingress Kong would also accept:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
spec:
  ingressClassName: kong
  rules:
    - http:
        paths:
          - {path: /api/orders, pathType: Prefix, backend: {service: {name: order-service, port: {number: 80}}}}
          - {path: /api,        pathType: Prefix, backend: {service: {name: user-service,  port: {number: 80}}}}
          - {path: /,           pathType: Prefix, backend: {service: {name: frontend,      port: {number: 80}}}}
```

**Versioned paths.** `/api/v1/orders` reaches order-service too: the route rewrites the prefix to
`/api/orders`, the path the service knows. Clients can name a version before a second one
exists; when order-service changes its API incompatibly, v2 becomes its own Deployment and
Service and gets a rule for `/api/v2/orders`, while v1 clients keep working until they move.

**Kong's admin API is a master key.** In DB-less mode one request to it replaces the whole
configuration: whoever reaches it can route every user's traffic anywhere. The chart's admin API
uses TLS but doesn't check who calls; the NetworkPolicy allows only the controller (enforced in
the lab and dev, everywhere from step 19). Proper mutual TLS needs certificates issued outside
Helm, which cert-manager (step 03's remainder) will do. Kong Manager, the admin GUI, is off.

**Client addresses.** Behind the edge, the client's address is in `X-Forwarded-For`. Kong trusts
that header only from private addresses (where the ALB and Traefik are), so a client can't
forge its address for rate limits (step 17) or logs.

## What the gateway checks (step 17)

Step 16 made Kong the way in; step 17 uses it for what a gateway is for. The rule for what
belongs where: concerns that are the same for every service and that should stop a bad
request before it costs anything (who is calling, how often, which headers a browser gets)
go to the gateway; anything that needs the business data (may *this* user see *this* order?)
stays in the service.

| Path | Checks at the gateway | Why |
|---|---|---|
| `/api/auth/signin`, `/api/auth/signup` | at most 10 a minute per client address (`auth-attempts`) | Password guessing at speed is the attack on a sign-in form |
| `/api/orders` (the browser's order API) | a valid sign-in token (`user-tokens`: RS256 against user-service's public key, not expired, at most 24 hours long, only in the `Authorization` header) | Forged and expired tokens are refused at the edge with 401. order-service still verifies every token: the gateway stops bad ones earlier, it doesn't replace the service's check |
| `/api/orders/status` | none | The synthetic checks (and anyone) may ask whether it's up |
| `/api/v1/orders` (the partner API) | an API key (`partner-keys`, removed before the request goes on), then the partner's tier: basic 60 a minute and 1,000 an hour, premium 600 and 20,000 (`partner-tier-*`); `X-Api-Version: 1` set for the service | Machine clients identify their *application* with a key; the user they act for still brings a sign-in token, which order-service checks |
| everything | `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `X-Frame-Options: DENY` on responses (`security-headers`); per-route and per-consumer metrics | The same for every response; nobody has to remember them per service |

The plugins: `platform/kong/plugins.yaml` (cluster-wide, attached by name) and
`apps/base/kong.yaml` (the service-side ones and the consumers); routes name theirs in a
`konghq.com/plugins` annotation (`apps/base/routes.yaml`).

**Rate limits that add up across pods.** With two gateway pods, a limit counted in each pod
("local") is really twice the limit, and a client hitting different pods sees inconsistent
answers. The counters are in **Valkey** (the Linux Foundation's open-source fork of Redis;
Kong speaks to it as Redis) in the `kong` namespace: in memory, password-protected, reachable
only from the gateways. ElastiCache (tf `enable_elasticache`) would be the managed version.
Kong's open-source limiter uses **fixed windows** (this minute, this hour): simple and cheap,
but a client can send a burst at the end of one window and another at the start of the next.
Sliding windows (Kong Enterprise's advanced limiter) or a token bucket smooth that out. If
Valkey is down, Kong lets requests through unlimited rather than refusing them all
(`fault_tolerant`), and `KongRateLimitStoreUnavailable` says so: an outage of the limiter
shouldn't be an outage of the application.

**Authentication, by audience.**

| Callers | Mechanism | Here |
|---|---|---|
| Users in the browser | Sign-in tokens (JWT, OAuth2/OIDC) | user-service's RS256 tokens, checked by Kong and by order-service |
| Partner applications | API keys per application, with tiers; OAuth2 client credentials for stronger needs | `/api/v1/orders` |
| Services inside the cluster | Mutual TLS, identities from the platform | The service mesh, step 18 |

**Ordering.** Kong runs a request's plugins in a fixed priority order, whatever order they are
listed in: authentication (jwt, key-auth), then rate limits (which can then count per
consumer), then request changes, then the proxying, then response changes. A plugin can be
attached globally, to a route, to a consumer (the tiers), or to a route and consumer together;
the most specific one wins.

**Secrets that never touch Git.** The Valkey password and the partner keys are generated
inside the cluster by External Secrets' Password generator (`platform/kong-redis-password.yaml`,
`apps/<env>/kong-credentials.yaml`); user-service's public key comes from Secrets Manager,
written by tf `scripts/set-secret.sh` with the signing key. In the lab, `scripts/start-lab.sh`
makes all three, once, into git-ignored files under `apps/local`.

**Not done here, on purpose.** *CORS*: the frontend calls its API from the same origin, so no
CORS headers are needed, and adding permissive ones would only loosen what browsers enforce;
the partner API is called from servers, where an API key in a browser would leak. *Weighted
canary routes*: Argo Rollouts drives those with health checks in step 20.

**Maintenance.** Naming the `maintenance` plugin on a route makes it answer 503 with a message
instead of reaching its service, e.g. during a database migration:
`kubectl annotate httproute order-service -n development konghq.com/plugins=user-tokens,maintenance --overwrite`,
and back to `user-tokens` afterwards (in Git, for anything but a short test).

## Where it runs

Every environment: Kong is how requests reach the services now. Two gateway pods across zones
in the cloud (one may go at a time), one in the lab. About 400 MiB in the lab.

**Alternatives.** AWS API Gateway (managed, per-request pricing, the natural choice for Lambda
backends or when you want no gateway to run; less natural for long-lived services in a cluster
and for configuration in Git), Apache APISIX, Envoy Gateway, Traefik as a gateway,
Emissary-ingress. All but the first implement the Gateway API too, which is part of why the
routes are written with it.

## Try it in the lab

After `scripts/sync-local-stack.rb`:

```bash
kubectl get gatewayclass,gateway -A          # kong: Accepted, Programmed
kubectl get httproute -n development         # frontend, user-service, order-service
curl -s localhost/api/orders/status          # through Traefik, then Kong
curl -s localhost/api/v1/orders/status       # the same service, by its versioned path
curl -sI localhost/api/orders/status | grep -i via   # "kong/3.9.x": the request passed through Kong
```

1. **Watch it.** Grafana → **Kong gateway**: requests per route, errors, latency, and how much
   of it is Kong.
2. **Break a route.** Point `order-service`'s route at a Service that doesn't exist
   (`kubectl edit httproute order-service -n development`, `name: order-servce`). Its status says
   `ResolvedRefs: False`, the controller leaves it out, `KongResourcesRejected` fires after 10
   minutes, and the edge checks for `/api/orders` fail while the rest keeps working. Change it
   back.
3. **Refused at the gateway (step 17).** Without a token, the order API never reaches
   order-service; with one, it does:

   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' localhost/api/orders/user/1     # 401, from Kong
   TOKEN=$(curl -s localhost/api/auth/signin -H 'Content-Type: application/json' \
     -d '{"username":"asha","password":"a-long-password"}' | jq -r .token)
   curl -s -o /dev/null -w '%{http_code}\n' localhost/api/orders/user/1 -H "Authorization: Bearer ${TOKEN}"
   #   now order-service answers: 200 if 1 is your ID, 403 if not; either way Kong let it through
   for i in $(seq 1 12); do curl -s -o /dev/null -w '%{http_code} ' localhost/api/auth/signin \
     -H 'Content-Type: application/json' -d '{"username":"asha","password":"wrong"}'; done; echo
   ```

   The loop answers 401 (wrong password, from user-service) until the tenth attempt of the
   minute, the sign-in above included, then 429 from Kong: the sign-in limit. The response
   headers say how many are left (`RateLimit-Remaining`).
4. **The partner tiers.** The lab's keys are in `apps/local/partner-api-keys.env`:

   ```bash
   . apps/local/partner-api-keys.env
   for i in $(seq 1 65); do curl -s -o /dev/null -w '%{http_code} ' localhost/api/v1/orders/status \
     -H "apikey: ${PARTNER_BASIC_KEY}"; done; echo                 # 60 × 200, then 429
   curl -s -o /dev/null -w '%{http_code}\n' localhost/api/v1/orders/status   # no key: 401
   ```

   The premium key still gets through. **Kong gateway** → "Requests by consumer" and "Refused
   at the gateway" show both.
5. **Try the admin API from a pod.**
   `kubectl run probe -n development --rm -it --image=busybox:1.37 --restart=Never -- wget -T 5 -qO- https://kong-gateway-admin.kong:8444/status`
   times out: only the controller is let through.

## Deploying to dev

Merging gitops installs the Gateway API CRDs, Kong and its configuration, and the services'
routes, and removes `app-ingress`. The ALB stays the same one as long as the `microservices`
group keeps a member throughout (the `/otlp` Ingress does). Check its address afterwards
(`kubectl get ingress kong-gateway-proxy -n kong`) and update tf's `synthetics_base_url` if it
changed. Nothing changes in the app or in Terraform.

Step 17 adds, in this order: tf apply `01-infra` (the empty `jwt-public-key` secret), then
`scripts/set-secret.sh dev jwt-public-key` in the tf repo (derives it from the signing key
already there, without signing anyone out); then merge gitops. External Secrets generates the
Valkey password and the partner keys in the cluster; hand a partner its key with
`kubectl get secret partner-basic-key -n development -o jsonpath='{.data.key}' | base64 -d`.
In the lab, run `scripts/start-lab.sh` once more, which makes the new Secrets.

## Exercises

1. Run the routing as the Ingress above instead of the HTTPRoutes (`ingressClassName: kong`) and
   compare what `kubectl describe` tells you about each when a Service is missing.
2. Deploy a second order-service release as `order-service-v2` and give it `/api/v2/orders`.
3. Move 10% of `/api/orders` to it with `backendRefs` weights (step 17 does this as a canary).
