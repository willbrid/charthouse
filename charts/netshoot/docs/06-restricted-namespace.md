# Running the toolbox in a `restricted` namespace

netshoot's defaults add `NET_RAW` and `NET_ADMIN`, which a namespace labelled
`pod-security.kubernetes.io/enforce: restricted` rejects outright. This scenario strips the pod down
to what that standard allows — a smaller toolbox, but one you can install in a namespace you do not
control.

## What still works, and what does not

| Tool | Under `restricted` |
|---|---|
| `dig`, `nslookup`, `host` | works |
| `curl`, `wget`, `nc`, `socat` | works |
| `openssl s_client` | works |
| `ss`, `netstat`, `ip addr` (read-only) | works |
| `mtr --tcp`, `traceroute -T` | works — TCP mode needs no raw socket |
| `ping`, `traceroute` (default UDP/ICMP) | **needs `NET_RAW`** |
| `tcpdump`, `tshark` | **needs `NET_RAW`** |
| `ip route add`, `tc`, `iptables`, `conntrack` | **needs `NET_ADMIN`** |
| `nsenter`, `bpftrace`, `perf` | **needs `SYS_ADMIN`** and host namespaces |

For most "can this pod reach that service" questions, the first half of the table is enough.

## Values

```yaml
# values-restricted.yaml
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

# All four of these are required by `restricted`; omit any one and admission
# rejects the pod.
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
    # No `add:` at all. NET_RAW is the one `restricted` refuses most visibly.

# The toolbox writes to $HOME and /tmp; the image's root filesystem is writable
# by default, but a namespace that also enforces a read-only root needs these.
volumes:
  - name: tmp
    emptyDir: {}

volumeMounts:
  - name: tmp
    mountPath: /tmp

serviceAccount:
  create: true
  automount: false

hostNetwork:
  enabled: false

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
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

helm install netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 \
  --namespace production \
  --values values-restricted.yaml
```

Check the pod against the policy without creating anything:

```bash
helm template netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --values values-restricted.yaml | kubectl -n production apply --dry-run=server -f -
```

The default values fail that same check, which is the point:

```
Error from server (Forbidden): pods "netshoot" is forbidden: violates PodSecurity
"restricted:latest": non-default capabilities (container "netshoot" must not
include "NET_ADMIN", "NET_RAW" in securityContext.capabilities.add)
```

## Verify

```bash
kubectl -n production exec deploy/netshoot -- id            # uid=65532
# no capabilities at all
kubectl -n production exec deploy/netshoot -- grep CapEff /proc/self/status
# 0000000000000000

# what still works
kubectl -n production exec deploy/netshoot -- dig +short kubernetes.default.svc.cluster.local
kubectl -n production exec deploy/netshoot -- nc -zv myservice 8080
kubectl -n production exec deploy/netshoot -- curl -sS -o /dev/null -w '%{http_code}\n' http://myservice:8080/healthz

# and what does not
kubectl -n production exec deploy/netshoot -- ping -c1 10.244.0.5 || echo "no NET_RAW: expected"
```

## What to know

- **`CapEff: 0000000000000000` is the confirmation.** Any non-zero value means a capability survived
  — compare with `0000000000003000` for the chart's default `NET_RAW` + `NET_ADMIN`.
- **`mtr --tcp` replaces `traceroute`.** TCP-mode probes use ordinary connect() calls, so they need
  no raw socket. The hop-by-hop view is coarser but it answers "where does it stop" just as well.
- **When you really need a capture**, do not weaken the namespace. Run
  [the node DaemonSet](02-per-node-daemonset.md) in a separate namespace under `privileged`, and
  capture the same traffic from the node side.
- **`automount: false` matters more here**, not less: a namespace hardened against privilege
  escalation should not have a toolbox holding an API token sitting in it.
- **The `restricted` standard is versioned.** Pinning `enforce-version` rather than using `latest`
  keeps a Kubernetes upgrade from tightening the rules under a running release — at the cost of not
  picking up new checks.
