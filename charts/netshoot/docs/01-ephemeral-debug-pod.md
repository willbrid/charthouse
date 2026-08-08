# A throwaway debug pod in a namespace

The reason netshoot exists: one pod, alive and doing nothing, that you exec into to look around a
namespace from the inside. Install it, debug, uninstall it. Nothing is exposed, nothing is stored.

## Values

```yaml
# values-debug.yaml
kind: Deployment
replicaCount: 1

image:
  repository: nicolaka/netshoot
  tag: "v0.16"
  pullPolicy: IfNotPresent

# The image entrypoint is a shell, so a container with no command exits at once.
# This is what keeps it alive and idle.
command:
  - "sh"
  - "-c"
  - "while true; do sleep 5; done"

# The default: enough for dig, curl, nc, openssl, ping and traceroute.
# NET_RAW is what ping and traceroute need; NET_ADMIN covers ip/tc/iptables.
securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_RAW
      - NET_ADMIN
  allowPrivilegeEscalation: false

# A toolbox has no business holding an API token.
serviceAccount:
  create: true
  automount: false

# A debug pod that outlives its usefulness is a debug pod someone finds later.
# Small enough that it cannot disturb the namespace it landed in.
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 256Mi

terminationGracePeriodSeconds: 5
```

## Install

```bash
helm install netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 \
  --namespace production \
  --values values-debug.yaml
```

Install it in the namespace you want to debug: pod-to-pod reachability, DNS search paths and any
NetworkPolicy in force all depend on where the pod runs.

## Use it

```bash
kubectl -n production exec -it deploy/netshoot -- bash
```

| Question | Command |
|---|---|
| Does this name resolve, and to what? | `dig +search myservice` — `nslookup myservice` for the short form |
| Is the port open from here? | `nc -zv myservice 8080` |
| What does the service actually answer? | `curl -sv http://myservice:8080/healthz` |
| Which endpoints is the service load-balancing to? | `dig +short myservice.production.svc.cluster.local` |
| Is the TLS certificate the one I expect? | `openssl s_client -connect myservice:443 -servername myservice </dev/null \| openssl x509 -noout -subject -dates` |
| Where do the packets go? | `traceroute -n 10.96.0.1` |
| What is on the wire? | `tcpdump -ni any port 8080 -c 20` |

## Uninstall as soon as you are done

```bash
helm uninstall netshoot --namespace production
```

## What to know

- **`kubectl debug` is often the better tool.** For a one-off look at a *running* pod's own network
  namespace, `kubectl debug -it <pod> --image nicolaka/netshoot --target <container>` needs no chart
  at all. This chart is for the cases where you want a pod that stays: a scheduled probe, a
  DaemonSet, something with a service in front, or a pod subject to a specific NetworkPolicy.
- **`ping <service>` failing is not a bug.** A ClusterIP is a virtual address handled by
  iptables/IPVS; nothing answers ICMP on it. Ping a pod IP instead, and use `nc`/`curl` for services.
- **The default capabilities are already more than the `restricted` Pod Security Standard allows.**
  In a namespace that enforces it, see [Restricted namespace](06-restricted-namespace.md).
- **Anything needing to enter another container's namespaces** (`nsenter`) needs `SYS_ADMIN` and
  `hostPID` — that is [Node debugging](02-per-node-daemonset.md), not this.
