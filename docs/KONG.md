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
| Global plugins | `platform/kong/plugins.yaml` | Prometheus metrics for every route |
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
3. **Try the admin API from a pod.**
   `kubectl run probe -n development --rm -it --image=busybox:1.37 --restart=Never -- wget -T 5 -qO- https://kong-gateway-admin.kong:8444/status`
   times out: only the controller is let through.

## Deploying to dev

Merging gitops installs the Gateway API CRDs, Kong and its configuration, and the services'
routes, and removes `app-ingress`. The ALB stays the same one as long as the `microservices`
group keeps a member throughout (the `/otlp` Ingress does). Check its address afterwards
(`kubectl get ingress kong-gateway-proxy -n kong`) and update tf's `synthetics_base_url` if it
changed. Nothing changes in the app or in Terraform.

## Exercises

1. Run the routing as the Ingress above instead of the HTTPRoutes (`ingressClassName: kong`) and
   compare what `kubectl describe` tells you about each when a Service is missing.
2. Deploy a second order-service release as `order-service-v2` and give it `/api/v2/orders`.
3. Move 10% of `/api/orders` to it with `backendRefs` weights (step 17 does this as a canary).
