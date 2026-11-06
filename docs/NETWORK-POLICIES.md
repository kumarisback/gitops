# Network policies: who may talk to whom

Roadmap step 19. Until a NetworkPolicy selects a pod, Kubernetes lets it reach every other
pod in the cluster and the whole internet, and lets every pod reach it. The service mesh
(step 18) already decides which identity may call which service, but only inside the mesh
and only for traffic that goes through it. A NetworkPolicy works one layer lower, on
addresses and ports, for every pod, in the mesh or not. Together: the network drops
whatever no flow needs, and the mesh refuses wrong identities and paths among what's left.

```
                    kong namespace                          application namespace
 ALB / Traefik ─8000─► gateway ─────────────15008────────► waypoint ─15008─► frontend
                        │   ▲ 8444                           ▲    └──15008─► user-service ─┐
                        │   └── controller ─► Kubernetes API │    └──15008─► order-service ─┤
                        └─6379─► kong-redis                  └─15008── (they call each other)
                                                                                           │
       out of the namespace: DNS, MongoDB Atlas (27017), the trace collector (4318),  ◄────┘
       Kafka (9093) and its schema registry (8080). Nothing else, and never the
       instance metadata service (169.254.169.254).
```

## The pieces

| Piece | Where | What it does |
|---|---|---|
| Enforcement | KinD's network plugin (lab, KinD 0.24 and later); tf `enable_network_policy` (the VPC CNI's policy agent, every environment) | Turns NetworkPolicy objects into dropped packets. Without it they are accepted and ignored |
| Application namespace | `apps/base/network-policies.yaml`; `apps/components/kafka-clients`, `apps/components/kafka-msk`; `apps/local/mongodb.yaml` | Deny everything, then one policy per workload saying what it accepts and what it calls |
| kong namespace | `platform/kong/network-policy.yaml`, `platform/kong/redis.yaml` | Deny everything; the gateways may reach only the waypoint and their rate-limit store |
| Kafka | `streaming/base/kafka.yaml` (`networkPolicyPeers`), `streaming/base/network-policies.yaml` | Who may connect to the brokers; Kafka UI and the registry (since step 13) |
| Synthetic checks | `addons/values/common/blackbox-exporter.yaml` | The exporter fetches any URL it is given, so it may reach only DNS and the namespaces it checks |
| AWS security groups | tf `modules/database`, `modules/msk` | Databases and MSK admit the cluster's security group, not an address range |
| The test | `tests/network-policies/` (run by `scripts/validate.sh`) | Evaluates each environment's rendered policies against the connections it must allow and refuse |

## Who may talk to whom

Application namespace (`development` in the lab and dev, `staging`, `production`). Every pod
may look up names (CoreDNS, port 53).

| Pod | Accepts | Calls |
|---|---|---|
| waypoint | Kong's gateways, user-service, order-service, the synthetic checks, Prometheus (15008); Prometheus on 15020 | the namespace's pods (15008), istiod (15012) |
| frontend | the waypoint (15008); the kubelet's checks on 80 | nothing |
| user-service | the waypoint, Prometheus (15008); the kubelet's checks on 8081 | the waypoint (to order-service), MongoDB on 27017, the trace collector on 4318, Kafka on 9093 and the registry on 8080 (lab, dev) |
| order-service | the same | the same (user-service's signing key through the waypoint) |
| notification-service | Prometheus (15008); the kubelet's checks on 8081 | the trace collector, Kafka, the registry |
| MongoDB (lab only) | user-service, order-service, its init Job (15008); the kubelet's checks on 27017 | nothing |

kong namespace:

| Pod | Accepts | Calls |
|---|---|---|
| gateway | anyone on the proxy (8000) and status (8100) ports: the edge and its health checks; the controller on the admin port (8444); Prometheus (15008) | the application namespace's waypoint (15008), kong-redis (6379) |
| controller | anyone on its admission webhook (the Kubernetes API calls it); Prometheus on its metrics ports | anything but the instance metadata service |
| kong-redis | the gateways (6379) | nothing |

## Design choices, and why

**Deny by default, then allow each flow.** Policies only ever add: once one selects a pod,
what no policy allows is dropped, and a pod no policy selects is wide open. So each
namespace here starts with `default-deny` (every pod, both directions), and each workload
gets one policy listing what it accepts and what it calls. A new pod in the namespace can do
nothing until someone writes down what it needs, which is the point. The roadmap's check,
that the frontend can't reach a backend, holds twice: its policy allows no calls, and the
backends accept nothing but the waypoint and Prometheus.

**Which namespaces.** The application namespace and `kong`: the ones that run this project's
code and face the internet. The others (monitoring, kafka, argocd, istio-system, keda,
external-secrets, kube-system) run vendors' charts, whose connections are the vendors'
to know: a default deny there means reverse-engineering each chart and checking again at
every upgrade, for little gain. They get targeted policies where something is exposed: Kafka
UI, the registry, the synthetic checks, the brokers' listener. The next candidates, in order:
`monitoring` (Grafana and Alertmanager accept anything today) and `argocd`.

**The mesh's port.** Between two pods in the mesh, ztunnel carries everything over port
15008 (HBONE), so that is the port these policies allow between them: a policy can't see the
port inside the tunnel. Which identity may reach which port and path inside it is the mesh's
job (`apps/base/mesh.yaml`; step 18 learned this the hard way, `docs/MESH.md`). Requests for
a Service always go to the waypoint first, so the backends accept 15008 from the waypoint,
not from their callers. Two more mesh details:

- In ambient mode the kubelet's health checks come from `169.254.7.127`, not the node, so
  every pod in the mesh lets that address in on its probe port (Istio's documentation asks
  for exactly this). Pods outside the mesh (the waypoint, Kong's controller, Valkey) are
  checked from their own node, which a NetworkPolicy can't block.
- Pods outside the mesh (CoreDNS, the brokers, the registry, the trace collector) are
  reached on their own ports: ztunnel passes those connections through unchanged.

**Out to the internet: by port, not by address.** The services reach the internet only on
the database's port (27017, MongoDB Atlas), and with MSK on 9098 and HTTPS (signing in to
AWS STS). A NetworkPolicy matches addresses, not names, and Atlas's and AWS's addresses
change, so the port is what can be pinned down. Tighter takes one of two things: private
endpoints (Atlas PrivateLink, an STS VPC endpoint), whose addresses are yours; or a CNI that
matches names (Cilium's `toFQDNs`, below).

**The instance metadata service.** `169.254.169.254` hands out the node's AWS credentials:
the node role, which may manage network interfaces, read every image in ECR and more. The
nodes allow two network hops to it (tf `modules/eks`, the launch template), so a pod can
reach it. No policy in the application or kong namespaces allows it, and the few wide rules
(the database's port, the controller's egress) exclude it by name, so even a policy that
someone widens later doesn't open it by accident. The services don't need it: they get their
own credentials through IRSA. The complete fix is on the nodes: one hop
(`http_put_response_hop_limit = 1`), so no pod in any namespace can reach it. Before that,
every add-on that reads it from a pod has to be given the answer instead; the AWS Load
Balancer Controller, for one, finds its VPC there (set its `vpcId` and `region` values
first). A change to try in a scratch cluster before dev.

**Kong's controller.** It must reach the Kubernetes API, whose address differs per cluster
(EKS's control plane in the VPC, KinD's control-plane node) and isn't a pod a policy can
name, so it may connect anywhere except the metadata service. The API reaches its admission
webhook from the same unnameable address, so that port is open to all; the webhook only
checks Kong resources before they are stored.

**Kafka's listener.** Every client must present a certificate (step 12), so the listener was
safe, but any pod could still try. `networkPolicyPeers` on the listener (Strimzi writes the
brokers' NetworkPolicy from it) admits the application namespaces, KEDA (it reads consumer
lag) and the kafka namespace itself. Strimzi's own components use the internal port 9091,
which Strimzi restricts on its own.

**Security groups: members, not address ranges.** In AWS the same question has a second
layer. The database and MSK security groups admitted every address in the VPC (RDS,
ElastiCache) or in the pod subnets (MSK): anything that ever got an address there, a load
balancer, a VPN, a new node group, could connect. They now admit the EKS cluster security
group, which every node carries (the managed node group and Karpenter's), and through the
node every pod. Each admits only its engine's port, and none allows egress: a database answers
connections, it doesn't open them. Narrower still are security groups for pods, which give
a pod its own group so that only the services reach the database; with Istio's ambient
mode they need the VPC CNI's `POD_SECURITY_GROUP_ENFORCING_MODE=standard`, or health
checks fail (Istio's platform notes).

**Why not Cilium.** Cilium (eBPF) would bring layer-7 policies (allow `GET /api/orders`, not
`DELETE`), egress by DNS name, and Hubble's view of every flow. The layer-7 part is already
done here, by the mesh's waypoint. The rest would mean replacing the VPC CNI (or chaining
Cilium to it), which is a cluster rebuild, not a policy change. The standard NetworkPolicy
API used here works the same under the VPC CNI, KinD's plugin, Calico and Cilium.

**A test instead of trust.** NetworkPolicies fail silently: a missing rule is a timeout
somewhere, an extra one is invisible. `tests/network-policies/check.rb` evaluates each
environment's rendered policies the way Kubernetes specifies them, against
`tests/network-policies/flows.yaml`: 60 to 80 connections per environment that must work
(Kong to the waypoint, the probes, DNS, Kafka) and must not (the frontend to a backend,
anything to the metadata service, the gateways to the internet). It also fails if any pod in
the two namespaces escapes the default deny. It models the specification, not a particular
plugin: the policies Strimzi writes and each plugin's quirks are outside it, which is what
the lab is for.

## Where it runs

Every environment. The lab enforces with KinD's built-in plugin; the cloud with the VPC CNI
as a managed EKS add-on with `enableNetworkPolicy` (tf `01-infra/main.tf`), on by default
since this step.

## Try it in the lab

After `scripts/sync-local-stack.rb`:

1. **What's in place.** `kubectl get networkpolicy -n development` and `-n kong`.
2. **The frontend can't reach a backend.** nginx's image has busybox's `wget`:

   ```bash
   kubectl exec -n development deploy/frontend -- wget -T 3 -qO- http://user-service/api/auth/jwks.json   # no answer, then fails
   kubectl exec -n development deploy/frontend -- nslookup user-service                                  # DNS still answers
   ```

3. **Two layers.** user-service may reach the waypoint, so this gets through the network,
   and the mesh refuses it (user-service may call only `GET /api/orders/user/*`):

   ```bash
   kubectl exec -n development deploy/user-service -- wget -qO- http://order-service/api/orders/status   # 403 RBAC: access denied
   ```

   The mesh answers at once (a 403, or a reset from ztunnel); a NetworkPolicy answers
   nothing, so the caller waits until it gives up.
4. **Change a rule and let the test catch it.** Delete the `169.254.7.127` rule from
   user-service's policy in `apps/base/network-policies.yaml` and run
   `./scripts/validate.sh`: the network policy check names the probe connection that would
   now fail. (Applied, the pods would turn unready.) Put it back.

There is no metadata service in KinD; try that one in dev.

## Deploying to dev

1. **tf first.** `enable_network_policy` is now on by default, which dev already had;
   staging and production get the managed VPC CNI add-on with enforcement (the aws-node pods
   restart once; running pods keep their network). Also in this apply: the security groups
   of the databases (staging and production run ElastiCache) and MSK switch from address
   ranges to the cluster security group, in place; open connections continue.
2. **Then gitops.** The policies apply as ArgoCD syncs; Kong's gateways restart once (usage
   reports off) and Strimzi updates the brokers' policy.
3. **Check** with the commands above, and the metadata service from a service's pod:
   `kubectl exec -n development deploy/order-service -- wget -T 3 -qO- http://169.254.169.254/`
   times out. On EKS, policies are enforced reliably only for pods a controller created
   (AWS's documentation): test from the services' own pods, not a `kubectl run` pod.

## When something can't connect

A NetworkPolicy drops packets without a word: the caller waits, then times out. From a pod
in the mesh, ztunnel waits instead and then closes the connection, so the caller sees it
closed after a delay, and ztunnel's log names the connection it couldn't open
(`kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep -i timed`). The mesh refuses
at once, with a 403 or a reset.

| Symptom | Likely cause |
|---|---|
| a pod in the mesh turns unready after a policy change | its policy doesn't let `169.254.7.127` in on the probe port |
| a new service gets nothing through Kong | it has no policy accepting 15008 from the waypoint (the waypoint may send to any pod; the pod must accept) |
| a service times out calling Kafka | the overlay lacks `apps/components/kafka-clients`, or its namespace isn't in the listener's `networkPolicyPeers` |
| works in the lab, not on EKS | the VPC CNI's agent: `kubectl get policyendpoints -n <namespace>` should list one per policy; the agent runs as the `aws-eks-nodeagent` container of the `aws-node` pods, and logs dropped connections when the add-on's `nodeAgent.enablePolicyEventLogs` is on |
| a pod outside the mesh fails its checks on EKS | the agent isn't letting the node in; check the add-on's version and the agent's log |

A new connection needs a rule in the right policy, and a line in
`tests/network-policies/flows.yaml` saying it must work.
