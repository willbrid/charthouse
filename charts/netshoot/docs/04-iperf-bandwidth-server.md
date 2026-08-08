# A permanent iperf3 target for bandwidth and latency testing

netshoot with a service in front, running `iperf3 -s`. Install one per zone or per node pool and you
have a fixed set of endpoints to measure the cluster network between — pod-to-pod inside a node,
across nodes, across availability zones.

## Values

```yaml
# values-iperf.yaml
kind: Deployment
replicaCount: 1

image:
  repository: nicolaka/netshoot
  tag: "v0.16"
  pullPolicy: IfNotPresent

# iperf3 -s stays in the foreground, so it is the pod's whole reason to live —
# no sleep loop needed here.
command:
  - "iperf3"
  - "-s"
args:
  - "--port"
  - "5201"

# Enabling the service publishes the ports below. The container ports are
# declared from this same list even when enabled is false.
service:
  enabled: true
  type: ClusterIP
  ports:
    - name: iperf
      port: 5201
      targetPort: 5201
      protocol: TCP
    # iperf3 uses the same port for UDP tests, declared separately because a
    # Service port entry carries one protocol.
    - name: iperf-udp
      port: 5201
      targetPort: 5201
      protocol: UDP

# iperf3 needs no capability at all: it opens ordinary sockets.
securityContext:
  capabilities:
    drop:
      - ALL
  allowPrivilegeEscalation: false

serviceAccount:
  create: true
  automount: false

# Pin the server so "between zones" means something. Run one release per zone
# with a different nodeSelector and release name.
nodeSelector:
  topology.kubernetes.io/zone: eu-west-1a

# An iperf run saturates what you give it — cap it, or a bandwidth test becomes
# a noisy-neighbour incident.
resources:
  requests:
    cpu: 200m
    memory: 128Mi
  limits:
    cpu: "2"
    memory: 512Mi
```

## Install one server per zone

```bash
for zone in eu-west-1a eu-west-1b eu-west-1c; do
  helm install "iperf-$zone" oci://ghcr.io/willbrid/charts/netshoot \
    --version 0.1.0 \
    --namespace netperf --create-namespace \
    --values values-iperf.yaml \
    --set nodeSelector."topology\.kubernetes\.io/zone"="$zone"
done
```

## Measure

```bash
# a client, anywhere you want to measure from
kubectl -n netperf run iperf-client --rm -it --restart=Never \
  --image nicolaka/netshoot -- \
  iperf3 -c iperf-eu-west-1b -p 5201 -t 10

# UDP, to see loss and jitter rather than throughput
kubectl -n netperf run iperf-client --rm -it --restart=Never \
  --image nicolaka/netshoot -- \
  iperf3 -c iperf-eu-west-1b -p 5201 -u -b 100M -t 10

# reverse direction — asymmetric paths are common
kubectl -n netperf run iperf-client --rm -it --restart=Never \
  --image nicolaka/netshoot -- \
  iperf3 -c iperf-eu-west-1b -p 5201 -R -t 10

# parallel streams, to tell a per-flow limit from a real one
kubectl -n netperf run iperf-client --rm -it --restart=Never \
  --image nicolaka/netshoot -- \
  iperf3 -c iperf-eu-west-1b -p 5201 -P 8 -t 10
```

## What to know

- **One test at a time per server.** `iperf3 -s` refuses a second concurrent client with
  `the server is busy running a test`. Run tests in sequence, or install more releases.
- **A single stream rarely reaches line rate.** If `-P 8` gets much more than `-P 1`, you are
  looking at a per-flow limit — a single CPU handling the interrupts, or an overlay's per-flow
  hashing — not at the network's ceiling.
- **Compare against the same-node case first.** Pin a client to the server's node
  (`--overrides` with a `nodeName`), measure, then go across nodes and across zones. The three
  numbers together tell you where the cost is; any one alone tells you nothing.
- **Cross-zone traffic is usually billed.** A `-t 60 -P 8` run moves real gigabytes across an
  availability-zone boundary. Keep the runs short.
- **The ports are declared on the pod even with `service.enabled: false`**, which is how you keep a
  port documented without publishing it — useful when a NetworkPolicy rule refers to it.
- Add a `NetworkPolicy` to restrict who may run tests against the server:
  [Testing NetworkPolicies](05-networkpolicy-probe.md) shows the shape.
