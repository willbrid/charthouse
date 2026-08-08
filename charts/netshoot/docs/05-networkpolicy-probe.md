# Reproducing a NetworkPolicy, to debug from inside it

A pod that is subject to the same network restrictions as the workload you are investigating. When
an application cannot reach a database and the policies look correct, the fastest answer comes from
a shell inside a pod the policy selects — with a toolbox in it.

Two opposite uses of the same values, both legitimate: **contain the toolbox** so a pod holding
`nmap` and `tcpdump` cannot reach whatever it likes, or **reproduce the restrictions** of another
workload to debug from under them.

## Values

```yaml
# values-policy.yaml
kind: Deployment
replicaCount: 1

image:
  repository: nicolaka/netshoot
  tag: "v0.16"
  pullPolicy: IfNotPresent

command:
  - "sh"
  - "-c"
  - "while true; do sleep 5; done"

securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_RAW
  allowPrivilegeEscalation: false

serviceAccount:
  create: true
  automount: false

networkPolicy:
  enabled: true
  labels:
    purpose: "debug-under-policy"
  # Left empty, the chart governs BOTH directions: enabling the policy alone
  # denies everything in and out except the DNS rule below. Naming one direction
  # explicitly leaves the other unrestricted.
  policyTypes: []
  # Without this, name resolution dies and every tool in the box goes with it.
  # This is the single most common mistake with an egress policy.
  allowDNS: true
  dns:
    namespace: kube-system
    podSelector:
      k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53

  # Nothing may open a connection to this pod. Remove the empty list and add
  # rules here to allow specific sources.
  ingress: []

  # Exactly what the application under investigation is allowed to reach —
  # copy its own policy here to reproduce its view of the network.
  egress:
    # The database, on its port only.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: databases
          podSelector:
            matchLabels:
              app.kubernetes.io/name: postgresql
      ports:
        - protocol: TCP
          port: 5432
    # An internal API in the same namespace.
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: billing-api
      ports:
        - protocol: TCP
          port: 8080
    # The internet, minus the cluster's own private ranges.
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
              - 10.0.0.0/8
              - 172.16.0.0/12
              - 192.168.0.0/16
      ports:
        - protocol: TCP
          port: 443

# A NetworkPolicy never selects a hostNetwork pod, and the chart refuses the
# combination outright rather than creating something nothing enforces.
hostNetwork:
  enabled: false

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

## Install

```bash
helm install netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 \
  --namespace production \
  --values values-policy.yaml
```

## Probe from inside the policy

```bash
kubectl -n production exec -it deploy/netshoot -- bash
```

```bash
# allowed — DNS
dig +short postgresql.databases.svc.cluster.local

# allowed — the database port
nc -zv postgresql.databases.svc.cluster.local 5432

# denied — same host, another port. A policy denial hangs until the timeout
# rather than refusing, which is how you tell it from "nothing is listening":
#   connection refused  → reached the host, no listener
#   timeout             → a policy dropped it
nc -zv -w 3 postgresql.databases.svc.cluster.local 5433

# denied — a namespace not in the rules
nc -zv -w 3 redis.cache.svc.cluster.local 6379

# allowed — HTTPS out
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' https://api.github.com

# denied — HTTP out, port 80 is not in the rules
curl -sS -m 5 http://example.com
```

## Prove the policy is what blocks it

```bash
# what the chart created
kubectl -n production describe networkpolicy netshoot

# and the A/B: delete it, retry, put it back
kubectl -n production delete networkpolicy netshoot
kubectl -n production exec deploy/netshoot -- nc -zv -w 3 redis.cache.svc.cluster.local 6379
helm upgrade netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 --namespace production --values values-policy.yaml
```

## What to know

- **The CNI enforces policies, not Kubernetes.** Calico, Cilium, Antrea, Weave and current kindnet
  builds do — verified here on Kind v0.29 (`kindnetd:v20250512`), where a pod under this policy
  reaches DNS and nothing else. Under a CNI that does not, the object is created and enforces
  nothing at all, silently. Run the A/B above on your own cluster rather than assuming.
- **Policies are additive and there is no deny rule.** Another policy in the namespace selecting the
  same pods can only *allow* more. If traffic you expect to be blocked gets through, look for the
  other policy: `kubectl -n production get networkpolicy`.
- **`policyTypes: []` governs both directions.** That is the chart's choice, and it makes
  `enabled: true` mean "deny everything but DNS". Setting `policyTypes: [Egress]` leaves ingress
  completely unrestricted — which is sometimes what you want, and always worth being deliberate
  about.
- **`namespaceSelector` and `podSelector` in one list entry mean AND** (that pod, in that
  namespace). As two separate entries under `to:`, they mean OR — a common and expensive mistake.
- **DNS goes to the kube-dns pods, not to the service IP.** `allowDNS` selects them by label in
  `kube-system`; check `kubectl get pods -n kube-system --show-labels` if resolution still fails on
  a cluster that names them differently.
- **Egress to the API server** needs its own rule — usually an `ipBlock` for the endpoint IP, since
  the `kubernetes` service has no pods to select. `kubectl get endpoints kubernetes` gives the
  address.
