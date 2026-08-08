# Node debugging — one pod per node on the host network

A DaemonSet sharing each node's network and PID namespaces: `ip addr` shows the node's interfaces,
`ps aux` lists the node's processes, and a capture sees the node's traffic rather than the pod's.
This is how you debug the CNI, kube-proxy rules, or a container whose own namespace you need to
enter.

**This is effectively root on every node.** Install it knowingly, for the duration of an
investigation, and uninstall it after.

## Values

```yaml
# values-node.yaml
kind: DaemonSet

# Ignored for this kind — the node count drives the pod count.
replicaCount: 1

image:
  repository: nicolaka/netshoot
  tag: "v0.16"
  pullPolicy: IfNotPresent

command:
  - "sh"
  - "-c"
  - "while true; do sleep 5; done"

hostNetwork:
  enabled: true
  # Left empty, the chart derives ClusterFirstWithHostNet. That is what keeps
  # *.svc.cluster.local resolving: on the host network the pod would otherwise
  # fall back to the node's resolver and lose the cluster domain entirely.
  dnsPolicy: ""
  # The node process table — how you find the pid of a given container before
  # entering its namespaces.
  hostPID: true
  hostIPC: false

securityContext:
  capabilities:
    drop:
      - ALL
    add:
      - NET_RAW        # ping, traceroute, raw sockets
      - NET_ADMIN      # ip, tc, iptables, conntrack
      - SYS_PTRACE     # reading /proc/<pid> of the node's processes
      # setns() on a network namespace refuses anything less than SYS_ADMIN:
      # NET_ADMIN and SYS_PTRACE together are not enough for `nsenter -t <pid> -n`.
      # Add it only while you actually need to enter another container.
      - SYS_ADMIN
  allowPrivilegeEscalation: false

# Node network state, read-only. /proc/net holds the socket, route and conntrack
# tables the toolbox reads.
volumes:
  - name: host-proc
    hostPath:
      path: /proc
      type: Directory

volumeMounts:
  - name: host-proc
    mountPath: /host/proc
    readOnly: true

# A node debugger that skips the control-plane nodes misses the nodes whose
# networking breaks in the most interesting ways.
tolerations:
  - operator: Exists

# On the host network a container port is a node port, and two pods of a
# DaemonSet on one node would conflict. No service here.
service:
  enabled: false
  ports: []

serviceAccount:
  create: true
  automount: false

resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## Install

```bash
helm install netshoot-node oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 \
  --namespace debug --create-namespace \
  --values values-node.yaml
```

## Use it

```bash
# pick the pod on the node you care about
kubectl -n debug get pods -o wide
kubectl -n debug exec -it netshoot-<suffix> -- bash
```

| Question | Command |
|---|---|
| What interfaces does the node have? | `ip -br addr` — the pod IP is the node IP here |
| What does kube-proxy program for this service? | `iptables -t nat -L KUBE-SERVICES -n \| grep <clusterIP>` |
| Which connections is the node tracking? | `conntrack -L \| head` |
| Who is listening on the node? | `ss -tulpn` — with `hostPID`, the process names resolve |
| What crosses the node's interface? | `tcpdump -ni eth0 port 6443 -c 50` |
| What does that container's own network look like? | see below |

### Entering a container's network namespace

```bash
# the pid of a process of the target container, from the node's process table
ps aux | grep '[m]y-app'
nsenter -t <pid> -n ip -br addr
nsenter -t <pid> -n ss -tulpn
nsenter -t <pid> -n tcpdump -ni any -c 20
```

This is the piece that needs `SYS_ADMIN`. With `NET_RAW`, `NET_ADMIN` and `SYS_PTRACE` only,
`nsenter -t <pid> -n` fails with `Operation not permitted` — verified, `setns()` on a network
namespace accepts nothing less.

## Uninstall

```bash
helm uninstall netshoot-node --namespace debug
```

## What to know

- **The derived `dnsPolicy` is the point of leaving it empty.** Set `hostNetwork.enabled: true` with
  an explicit `dnsPolicy: ClusterFirst` and the pod silently loses cluster DNS — every
  `*.svc.cluster.local` lookup fails while everything else works, which is a confusing half-hour.
- **A NetworkPolicy never applies to a hostNetwork pod.** The chart fails the render on that
  combination rather than creating a policy nothing enforces; `networkPolicy.allowHostNetwork: true`
  overrides it if a single values file drives several releases.
- **`tolerations: [operator: Exists]` covers every taint**, control-plane and NoExecute included.
  That is deliberate for a node debugger.
- **Drop `SYS_ADMIN` when you are not using `nsenter`.** The rest of the table above works without
  it, and it is the capability that makes this pod equivalent to root on the node.
- **`bpftrace` and `perf` need `SYS_ADMIN` too**, plus a seccomp profile that allows `bpf()` — the
  `RuntimeDefault` profile blocks it. Set `podSecurityContext.seccompProfile.type: Unconfined` for
  those, and understand what you are turning off.
