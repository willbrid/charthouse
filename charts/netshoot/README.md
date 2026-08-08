# netshoot

A Helm chart for installing [netshoot](https://github.com/nicolaka/netshoot) in Kubernetes — as a
Deployment, a StatefulSet or a DaemonSet.

netshoot is not a service: it is a container packed with network troubleshooting tools (`tcpdump`,
`dig`, `curl`, `iproute2`, `iperf3`, `mtr`, `nmap`, `conntrack`, `bpftrace`, …) that you keep running
in a cluster and open a shell into when something on the network needs to be looked at.

| | |
|---|---|
| Chart | `oci://ghcr.io/willbrid/charts/netshoot` |
| Source | [charthouse](https://github.com/willbrid/charthouse/tree/main/charts/netshoot) |
| Container image | [`nicolaka/netshoot`](https://hub.docker.com/r/nicolaka/netshoot) (Docker Hub) |
| Upstream documentation | [github.com/nicolaka/netshoot](https://github.com/nicolaka/netshoot) |

---

## Contents

- [Container image](#container-image)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Example scenarios](#example-scenarios)
- [Using the toolbox](#using-the-toolbox)
- [Configuration](#configuration)
  - [Choosing a workload kind](#choosing-a-workload-kind)
  - [Keeping the container alive: `command`](#keeping-the-container-alive-command)
  - [Security context](#security-context)
  - [Host namespaces: `hostNetwork`](#host-namespaces-hostnetwork)
  - [Environment variables](#environment-variables)
  - [Volumes](#volumes)
  - [Per-pod storage (StatefulSet)](#per-pod-storage-statefulset)
  - [NetworkPolicy](#networkpolicy)
  - [Exposing a port](#exposing-a-port)
- [Recipes](#recipes)
- [Values](#values)
- [CI scenarios](#ci-scenarios)
- [Known limitations](#known-limitations)

---

## Container image

This chart builds and hosts no image. It deploys the upstream **netshoot** image published on
Docker Hub: **[hub.docker.com/r/nicolaka/netshoot](https://hub.docker.com/r/nicolaka/netshoot)**,
whose source and tool list live at
**[github.com/nicolaka/netshoot](https://github.com/nicolaka/netshoot)**.

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `nicolaka/netshoot` | Docker Hub repository |
| `image.tag` | `""` → chart `appVersion` (`v0.16`) | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |

The image is ~200 MB and holds a large toolbox, so the first pull on a node is not instant — worth
knowing before rolling a DaemonSet across a big cluster.

```yaml
image:
  repository: nicolaka/netshoot
  tag: "v0.16"
  pullPolicy: IfNotPresent
```

> **Pin a tag.** `latest` is convenient but not reproducible: the toolbox content changes from one
> netshoot release to the next, and two pods of the same release should hold the same tools. The
> chart already pins `appVersion`, so leaving `image.tag` empty is a pinned install.

`image.repository` also accepts a private mirror of that same image, combined with
`imagePullSecrets` when the registry requires credentials — the usual case in an air-gapped cluster,
where a debug toolbox is exactly what you need and Docker Hub is exactly what you do not have.

---

## Prerequisites

| Requirement | Minimum version |
|-------------|-----------------|
| Kubernetes | `1.30` |
| Helm | `3.8` (OCI support) |

The chart is distributed **only** as an OCI artifact on `ghcr.io` — there is no `helm repo add`
index. A Helm client older than `3.8` cannot pull it at all.

```bash
helm version --short   # must report v3.8.0 or later
```

---

## Install

```bash
# Latest published version, default values
helm install netshoot oci://ghcr.io/willbrid/charts/netshoot

# Pinned version, own values, dedicated namespace
helm install netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 \
  --namespace debug --create-namespace \
  --values my-values.yaml
```

`my-values.yaml` only holds what you override; everything else falls back to
[`values.yaml`](values.yaml).

Inspect before installing:

```bash
helm show values oci://ghcr.io/willbrid/charts/netshoot    # all available values
helm template netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --values my-values.yaml                                  # rendered manifests
helm install netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --values my-values.yaml --dry-run --debug                # server-side validation
```

### Upgrade

```bash
helm upgrade netshoot oci://ghcr.io/willbrid/charts/netshoot \
  --version 0.1.0 --namespace debug --values my-values.yaml
```

Changing `configmap` or `secret` alone restarts the pods: the workload carries `checksum/configmap`
and `checksum/secret` annotations computed from the rendered objects.

### Uninstall

```bash
helm uninstall netshoot --namespace debug
```

> PVCs created from `volumeClaimTemplates` are **not** deleted with the release — Kubernetes keeps
> them, so captures taken by the pods survive the uninstall. Remove them explicitly when they are no
> longer wanted: `kubectl delete pvc -l app.kubernetes.io/instance=netshoot -n debug`.

### `helm test`

```bash
helm test netshoot --namespace debug
```

The test runs a pod from the netshoot image itself: it checks the image is pullable and its toolbox
runs, resolves the cluster DNS, and resolves the services the release created. It stops at name
resolution and never connects to a port — a netshoot service publishes a listener somebody starts by
hand inside a pod, so an unanswered port is the normal state.

---

## Example scenarios

Complete values files, one per installation shape, in [`docs/`](docs/). Each page carries the values,
the install command and how to check the result.

| # | Scenario | What it covers |
|---|---|---|
| 1 | [Throwaway debug pod](docs/01-ephemeral-debug-pod.md) | One idle pod to exec into, default capabilities, and when `kubectl debug` is the better tool |
| 2 | [Node debugging](docs/02-per-node-daemonset.md) | DaemonSet on `hostNetwork` + `hostPID`, host `/proc`, `nsenter` and the `SYS_ADMIN` it requires |
| 3 | [Rolling packet capture](docs/03-capture-to-pvc.md) | StatefulSet, one PVC per pod through `volumeClaimTemplates`, retrieving a pcap |
| 4 | [iperf3 bandwidth target](docs/04-iperf-bandwidth-server.md) | A service in front of the toolbox, one release per zone, measuring across nodes |
| 5 | [NetworkPolicy probe](docs/05-networkpolicy-probe.md) | Debugging from inside a policy, and proving it is the policy that blocks |
| 6 | [Restricted namespace](docs/06-restricted-namespace.md) | No capabilities at all — which tools survive the `restricted` Pod Security Standard |

---

## Using the toolbox

```bash
export POD=$(kubectl get pods -n debug \
  -l app.kubernetes.io/name=netshoot,app.kubernetes.io/instance=netshoot \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -it -n debug $POD -- bash
```

A few things worth running from inside, and what they prove:

| Command | Answers |
|---|---|
| `dig +short my-svc.my-ns.svc.cluster.local` | Does cluster DNS resolve this service? |
| `dig +short @10.96.0.10 example.com` | Is CoreDNS forwarding to the outside? |
| `nc -zv my-svc.my-ns.svc 8080` | Is the port open, i.e. does the service have ready endpoints? |
| `curl -sv http://my-svc.my-ns.svc:8080/` | Does the application answer, and with what? |
| `ip -br addr` / `ip route` | What the pod network looks like from inside |
| `tcpdump -i any -n port 53` | What actually goes over the wire (needs `NET_RAW`) |
| `mtr -n 10.0.0.1` | Where the packets stop, and where they are lost |
| `openssl s_client -connect host:443` | Which certificate is served, by whom |
| `iperf3 -c other-pod` | Throughput between two points |

The complete tool list is maintained upstream at
[github.com/nicolaka/netshoot](https://github.com/nicolaka/netshoot).

> **`kubectl debug` vs this chart.** For a one-off look at a single pod, `kubectl debug -it <pod>
> --image=nicolaka/netshoot` is faster and leaves nothing behind. This chart is for the other cases:
> a toolbox that stays available to a team, one pod per node, a pod with persistent storage for
> captures, or a pod deliberately placed under a NetworkPolicy to reproduce what another workload
> sees.

---

## Configuration

| Section | Description |
|---|---|
| `kind` | Workload type: `Deployment`, `StatefulSet` or `DaemonSet` |
| `replicaCount` | Number of pods (not for a DaemonSet) |
| `command`, `args` | What the container runs — the sleep loop by default |
| `image` | Container image and pull policy |
| `podSecurityContext`, `securityContext` | Privileges, i.e. which tools work |
| `hostNetwork` | Host network, PID and IPC namespaces, and the DNS policy that goes with them |
| `configmap`, `secret`, `env`, `envFrom` | Environment variables |
| `volumes`, `volumeMounts` | Extra volumes, whatever the kind |
| `volumeClaimTemplates` | Per-pod PersistentVolumeClaims (StatefulSet only) |
| `networkPolicy` | Traffic allowed to and from the netshoot pods |
| `service` | Optional service, to publish a listener started inside the pod |
| `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` | Scheduling and limits |
| `livenessProbe`, `readinessProbe`, `startupProbe` | Health checks — only useful when `command` runs a server |

Incoherent combinations are rejected at render time rather than silently ignored: an unknown `kind`,
`volumeClaimTemplates` outside a StatefulSet, a claim without a size, a volume colliding with a
claim, a service enabled without a port, a NetworkPolicy on hostNetwork pods.

### Choosing a workload kind

The pod is identical in the three cases — only the controller around it changes.

```yaml
kind: Deployment    # or StatefulSet, or DaemonSet
```

| Kind | Use it for | Comes with |
|------|-----------|------------|
| `Deployment` (default) | An interchangeable debug pod, the everyday `kubectl exec` target | `replicaCount`, `deployment.strategy` |
| `StatefulSet` | Captures that must survive a restart, and pods reachable at a predictable DNS name | `volumeClaimTemplates`, a headless service, `statefulSet.podManagementPolicy` |
| `DaemonSet` | One pod per node, to look at the network of every node | One pod per node; `replicaCount` does not apply |

A StatefulSet also gets a headless service `<fullname>-headless`, created whatever `service.enabled`
says, which is what gives each pod a stable name:

```
netshoot-0.netshoot-headless.debug.svc.cluster.local
netshoot-1.netshoot-headless.debug.svc.cluster.local
```

That is what makes a point-to-point test reproducible: `iperf3 -c netshoot-0.netshoot-headless`
always reaches the same pod, wherever it was rescheduled.

### Keeping the container alive: `command`

The netshoot image entrypoint is a shell, so a container started without a command exits as soon as
it is created and the pod ends in `CrashLoopBackOff`. The default `command` is the sleep loop that
keeps the toolbox alive and waiting for `kubectl exec`:

```yaml
command:
  - "sh"
  - "-c"
  - "while true; do sleep 5; done"
args: []
```

Replace it to run a tool unattended instead:

```yaml
# An iperf3 server, reachable through service.ports
command: ["iperf3", "-s"]

# A capture running for the life of the pod, written to a PVC
command:
  - "sh"
  - "-c"
  - "tcpdump -i any -U -w /captures/$(hostname).pcap 'port 53'"
```

`terminationGracePeriodSeconds` defaults to `5` rather than the Kubernetes `30`: the sleep loop traps
nothing and exits on the first signal, so there is no reason to wait on every upgrade or deletion.
Raise it when your `command` needs time to flush something — a capture closing its file, for
instance.

### Security context

This is the value to think about with netshoot: most of its tools need privileges an ordinary
workload does not have.

| Tools | Needs |
|---|---|
| `dig`, `curl`, `nc`, `openssl`, `nslookup` | nothing |
| `ping`, `mtr`, `hping3`, `nmap -sS`, `tcpdump`, `tshark` | `NET_RAW` |
| `ip route/rule/link`, `tc`, `iptables`, `conntrack` | `NET_ADMIN` |
| `nsenter` into another container's namespaces | `SYS_ADMIN` — `NET_ADMIN` and `SYS_PTRACE` are **not** enough, `setns()` refuses anything less |
| `bpftrace`, `perf` | `SYS_ADMIN` and a matching seccomp profile, sometimes `privileged: true` |

The chart default is the tightest context that still leaves a usable toolbox — everything dropped,
`NET_RAW` and `NET_ADMIN` added back, no privilege escalation:

```yaml
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_RAW, NET_ADMIN]
  allowPrivilegeEscalation: false
```

Two other profiles worth knowing:

```yaml
# Restricted — enough for dig, curl, nc, openssl. Passes the `restricted` Pod
# Security Standard, which the default above does not.
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65534
  seccompProfile:
    type: RuntimeDefault
securityContext:
  capabilities:
    drop: [ALL]
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```

```yaml
# Full node debugging: tc, bpftrace, nsenter into another container. This is
# equivalent to root on the node — install it knowingly, and prefer a short-lived
# release over leaving it running.
securityContext:
  privileged: true
```

> **Pod Security Admission.** A namespace labelled `pod-security.kubernetes.io/enforce=restricted`
> rejects the chart default (added capabilities, root user) and everything above it. Either install
> netshoot in a `baseline`/`privileged` namespace, or use the restricted profile above and accept the
> smaller toolbox. Do not relax the label of a shared namespace to fit the toolbox in.

### Host namespaces: `hostNetwork`

```yaml
hostNetwork:
  enabled: false     # own network namespace and pod IP
  dnsPolicy: ""      # derived: ClusterFirstWithHostNet when enabled, ClusterFirst otherwise
  hostPID: false
  hostIPC: false
```

| `enabled` | What the pod sees |
|---|---|
| `false` (default) | The pod network, as an ordinary workload sees it — service resolution, NetworkPolicies, pod-to-pod routing. This is the right setting to reproduce what an application experiences. |
| `true` | The network namespace of its node — `ip addr` lists the node interfaces, `tcpdump` captures the node traffic, `conntrack -L` reads the node table. Ports opened in the container are opened on the node. |

Three things follow from `enabled: true`, and the chart handles or reports each of them:

- **DNS.** A hostNetwork pod keeping the default `ClusterFirst` falls back to the resolver of its
  node and stops resolving `*.svc.cluster.local` — the first thing you would ask a network toolbox
  to do. The chart therefore derives `ClusterFirstWithHostNet`. Override it with
  `hostNetwork.dnsPolicy` if you actually want the node view.
- **Ports.** A container port is a node port. The chart mirrors each `service.ports` entry into a
  `hostPort`, which makes the conflict visible at scheduling time instead of at runtime — but two
  pods of the same DaemonSet still cannot share a node port, so publishing ports from a hostNetwork
  DaemonSet is rarely what you want.
- **NetworkPolicies do not apply.** See below.

`hostPID: true` adds the node process table, which is how you find the pid of a given container.
Entering its namespaces with `nsenter -t <pid> -n` — the usual way to debug a pod that holds no shell
of its own — additionally requires `SYS_ADMIN`:

```yaml
hostNetwork:
  enabled: true
  hostPID: true
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_RAW, NET_ADMIN, SYS_ADMIN]
```

`SYS_PTRACE` is not a substitute: it lets you read `/proc/<pid>`, not join a namespace.

### Environment variables

Four ways in, meant for different things:

```yaml
# Non-sensitive — rendered into the ConfigMap <fullname>, pulled in with envFrom
configmap:
  TARGET_HOST: "api.default.svc.cluster.local"
  TARGET_PORT: "8080"

# Sensitive — rendered into the Secret <fullname>, pulled in with envFrom
secret:
  API_TOKEN: "changeme"

# Individual variables, including the downward API
env:
  - name: NODE_NAME
    valueFrom:
      fieldRef:
        fieldPath: spec.nodeName

# Whole objects created outside this chart
envFrom:
  - configMapRef:
      name: an-existing-configmap
  - secretRef:
      name: an-existing-secret
```

The ConfigMap and the Secret are created **only** when their map is non-empty, and both are named
after the release (`<fullname>`). Changing either rolls the pods, through the checksum annotations on
the pod template.

> **A Secret on a debug pod is barely a secret.** Anybody able to `kubectl exec` into these pods —
> which is the whole point of the chart — reads it back with `env`. Put throwaway credentials there,
> not production ones, and keep `serviceAccount.automount` at its `false` default so an exec'd user
> does not find an API token mounted next to them.

### Volumes

`volumes` and `volumeMounts` are passed through as written, for every kind:

```yaml
volumes:
  - name: scratch
    emptyDir: {}
  - name: host-proc
    hostPath:
      path: /proc
      type: Directory

volumeMounts:
  - name: scratch
    mountPath: /scratch
  - name: host-proc
    mountPath: /host/proc
    readOnly: true
```

A volume declared here is shared by every pod or ephemeral. For storage that belongs to one pod and
survives its restarts, use `volumeClaimTemplates`.

### Per-pod storage (StatefulSet)

`volumeClaimTemplates` creates one PVC per entry **and per pod**, named
`<entry>-<statefulset>-<ordinal>`, bound to its ordinal for the life of the set. It requires
`kind: StatefulSet`; asking for it under another kind fails the render rather than silently dropping
the storage.

```yaml
kind: StatefulSet
replicaCount: 2

volumeClaimTemplates:
  - name: captures
    size: 5Gi
    mountPath: /captures          # mounted for you
    accessModes: [ReadWriteOnce]
    storageClassName: standard
  - name: results
    size: 1Gi
    mountPath: /results
    enabled: false                # declared, but nothing is created
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Volume name and PVC name prefix |
| `size` | yes | Requested capacity |
| `enabled` | no (`true`) | `false` keeps the entry in the file and creates nothing — how a values file turns storage off without losing its own configuration |
| `mountPath` | no | Mounts the volume there. Left out, the PVC is created but not mounted: add a `volumeMounts` entry with the same name |
| `subPath`, `readOnly` | no | Refine that mount |
| `accessModes` | no (`[ReadWriteOnce]`) | |
| `storageClassName` | no | Defaults to the cluster default StorageClass |
| `volumeMode`, `selector`, `labels`, `annotations` | no | |

Combined with a capturing `command`, this is the shape that keeps a capture across a pod restart:

```yaml
command:
  - "sh"
  - "-c"
  - "tcpdump -i any -U -w /captures/$(hostname).pcap 'port 53'"
```

Copy the files out with `kubectl cp -n debug netshoot-0:/captures/netshoot-0.pcap ./capture.pcap`.

### NetworkPolicy

```yaml
networkPolicy:
  enabled: true
```

That alone renders a policy governing **both directions**: nothing gets in, nothing gets out except
the cluster DNS (`allowDNS: true`). Rules are then added back explicitly:

```yaml
networkPolicy:
  enabled: true
  allowDNS: true
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 5201
  egress:
    # everything inside the cluster, nothing outside it
    - to:
        - namespaceSelector: {}
```

Two opposite reasons to use it, both legitimate:

- **Contain the toolbox** — a pod holding `tcpdump` and `nmap` should not be able to reach whatever
  it likes on the cluster network, especially one left installed permanently.
- **Reproduce a restriction** — debug from a pod subject to the same rules as the workload you are
  investigating, and see the failure yourself instead of inferring it.

| Value | Default | Meaning |
|---|---|---|
| `policyTypes` | `[]` → `[Ingress, Egress]` | A direction absent from this list is a direction the policy does not restrict at all. Set it explicitly to govern only one. |
| `allowDNS` | `true` | Egress rule to the cluster DNS, added on top of `egress`. Without it, an egress policy breaks every name resolution in the pod. |
| `dns.namespace`, `dns.podSelector`, `dns.ports` | CoreDNS in `kube-system` | Where the DNS service is. Check `kubectl get pods -n kube-system --show-labels` if resolution breaks. |
| `ingress`, `egress` | `[]` | Rules in the format of the NetworkPolicy spec |
| `annotations`, `labels` | `{}` | On the policy object itself |
| `allowHostNetwork` | `false` | See below |

Two things to know before relying on it:

- **The CNI enforces it, not Kubernetes.** Under a plugin that ignores NetworkPolicies the object is
  created and restricts nothing, silently. Calico, Cilium, Antrea, Weave and current kindnet builds
  enforce them — verified here on Kind v0.29 (`kindnetd:v20250512`), where a pod under the default
  policy loses everything but DNS. Older kindnet builds did not. Rather than trust a list, check your
  own cluster: install with `networkPolicy.enabled=true` and try to reach something it forbids.
- **It never applies to hostNetwork pods.** A NetworkPolicy selects pods on the pod network, so with
  `hostNetwork.enabled: true` the policy would exist and do nothing. The chart fails the render
  rather than handing you that false sense of containment; set `networkPolicy.allowHostNetwork: true`
  to create it anyway (useful when one values file drives several releases and only some run on the
  host network).

### Exposing a port

netshoot needs no service to be exec'd into, so `service.enabled` is `false` by default. Turn it on
to publish a listener you start inside the pod — an `iperf3 -s`, a `nc -l`, a `python3 -m
http.server`:

```yaml
service:
  enabled: true
  type: ClusterIP
  ports:
    - name: iperf
      port: 5201
      targetPort: 5201
      protocol: TCP
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Unique, 15 characters max (Kubernetes constraint) |
| `port` | yes | Port exposed by the service |
| `targetPort` | no | Container port; defaults to the port name, which resolves to `port` |
| `protocol` | no | `TCP` (default) or `UDP` |
| `nodePort` | no | Honoured by `type: NodePort` and `LoadBalancer` only |

`service.ports` declares the container ports whether the service is enabled or not, so a port can be
documented on the pod without publishing anything. Enabling the service with an empty `ports` list is
rejected.

---

## Recipes

**The everyday toolbox, one pod, restricted egress.**

```yaml
kind: Deployment
replicaCount: 1
networkPolicy:
  enabled: true
  egress:
    - to:
        - namespaceSelector: {}   # the cluster, and nothing outside it
```

**One pod per node, on the host network, to debug the nodes themselves.**

```yaml
kind: DaemonSet
hostNetwork:
  enabled: true
  hostPID: true
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_RAW, NET_ADMIN, SYS_PTRACE]
  allowPrivilegeEscalation: false
volumes:
  - name: host-proc
    hostPath: {path: /proc, type: Directory}
volumeMounts:
  - name: host-proc
    mountPath: /host/proc
    readOnly: true
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

**Two pods with stable names, for a throughput test between two nodes.**

```yaml
kind: StatefulSet
replicaCount: 2
statefulSet:
  podManagementPolicy: Parallel
command: ["iperf3", "-s"]
service:
  enabled: true
  ports:
    - name: iperf
      port: 5201
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: netshoot
```

Then, from pod 0: `iperf3 -c netshoot-1.netshoot-headless`.

**A permanent DNS capture kept on disk.**

```yaml
kind: StatefulSet
replicaCount: 1
command:
  - "sh"
  - "-c"
  - "tcpdump -i any -U -w /captures/$(hostname).pcap 'port 53'"
volumeClaimTemplates:
  - name: captures
    size: 5Gi
    mountPath: /captures
```

---

## Values

### Workload

| Value | Default | Description |
|---|---|---|
| `kind` | `Deployment` | `Deployment`, `StatefulSet` or `DaemonSet` |
| `replicaCount` | `1` | Number of pods; ignored by `DaemonSet` |
| `deployment.strategy` | `{}` | Deployment update strategy |
| `statefulSet.podManagementPolicy` | `OrderedReady` | `Parallel` starts every pod at once |
| `statefulSet.updateStrategy` | `{}` | |
| `daemonSet.updateStrategy` | `{}` | |
| `terminationGracePeriodSeconds` | `5` | |
| `priorityClassName` | `""` | |

### Container

| Value | Default | Description |
|---|---|---|
| `image.repository` | `nicolaka/netshoot` | |
| `image.tag` | `""` (chart `appVersion`) | |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `command` | `["sh","-c","while true; do sleep 5; done"]` | Keeps the container alive |
| `args` | `[]` | |
| `resources` | `{}` | |
| `livenessProbe`, `readinessProbe`, `startupProbe` | `{}` | Only useful when `command` runs a server |

### Security and host access

| Value | Default | Description |
|---|---|---|
| `podSecurityContext` | `{}` | |
| `securityContext` | drops `ALL`, adds `NET_RAW`, `NET_ADMIN`, no privilege escalation | |
| `hostNetwork.enabled` | `false` | Share the node network namespace |
| `hostNetwork.dnsPolicy` | `""` | Derived: `ClusterFirstWithHostNet` / `ClusterFirst` |
| `hostNetwork.hostPID` | `false` | |
| `hostNetwork.hostIPC` | `false` | |
| `serviceAccount.create` | `true` | |
| `serviceAccount.automount` | `false` | No API token mounted next to an exec'd user |
| `serviceAccount.annotations`, `serviceAccount.name` | `{}`, `""` | |

### Environment, storage, network

| Value | Default | Description |
|---|---|---|
| `configmap` | `{}` | Non-sensitive env vars → ConfigMap `<fullname>` |
| `secret` | `{}` | Sensitive env vars → Secret `<fullname>` |
| `env` | `[]` | Individual variables, downward API included |
| `envFrom` | `[]` | Pre-existing ConfigMaps/Secrets |
| `volumes`, `volumeMounts` | `[]` | Extra volumes, any kind |
| `volumeClaimTemplates` | `[]` | Per-pod PVCs, StatefulSet only |
| `service.enabled` | `false` | |
| `service.type`, `service.annotations`, `service.ports` | `ClusterIP`, `{}`, `[]` | |
| `networkPolicy.enabled` | `false` | |
| `networkPolicy.allowDNS` | `true` | |
| `networkPolicy.policyTypes`, `ingress`, `egress` | `[]` | |

### Scheduling

| Value | Default |
|---|---|
| `nodeSelector`, `affinity` | `{}` |
| `tolerations`, `topologySpreadConstraints` | `[]` |
| `podAnnotations`, `podLabels` | `{}` |
| `nameOverride`, `fullnameOverride` | `netshoot` |

---

## CI scenarios

[`ci/`](ci/) holds the values files chart-testing installs on a Kind cluster. Each one covers a
distinct shape of the chart:

| Scenario | Covers |
|---|---|
| [`scenario-basic-values.yaml`](ci/scenario-basic-values.yaml) | Deployment, two replicas, ConfigMap + Secret + downward API env vars, default security context, `emptyDir` volume |
| [`scenario-statefulset-values.yaml`](ci/scenario-statefulset-values.yaml) | StatefulSet, headless service, two `volumeClaimTemplates` (one disabled), automatic mounting, a `tcpdump` command writing to the PVC |
| [`scenario-daemonset-hostnetwork-values.yaml`](ci/scenario-daemonset-hostnetwork-values.yaml) | DaemonSet, `hostNetwork` + `hostPID`, derived `ClusterFirstWithHostNet`, host mount, control-plane tolerations, `replicaCount` ignored |
| [`scenario-networkpolicy-values.yaml`](ci/scenario-networkpolicy-values.yaml) | NetworkPolicy with both directions governed, DNS rule, ingress and egress rules |

The NetworkPolicy scenario proves the object is created, valid and selecting the right pods. It does
**not** prove traffic is blocked: the kindnet CNI of a default Kind cluster accepts NetworkPolicies
and enforces none. Enforcement belongs to a run on Calico or Cilium.

---

## Known limitations

- **A permanently installed toolbox is a permanently installed toolbox.** `tcpdump`, `nmap` and
  `nsenter` in a long-lived pod are useful to your team and to anybody who obtains `exec` on that
  namespace. Restrict `pods/exec` with RBAC, keep the pod in its own namespace, use
  `networkPolicy` to bound what it can reach, and prefer `kubectl debug` for one-off investigations.
- **The restricted Pod Security Standard and the default security context are incompatible.** Added
  capabilities and a root user are what the tools need; a `restricted` namespace refuses them. Pick
  one — see [Security context](#security-context).
- **`hostNetwork` and NetworkPolicies do not mix**, and the chart refuses the combination by default.
- **No RBAC is created.** The chart mounts no API token (`serviceAccount.automount: false`) and
  grants nothing. Tools that talk to the API server need a Role and a RoleBinding you provide, and
  `serviceAccount.automount: true`.
- **No autoscaling.** A debug toolbox scaling on CPU makes no sense; use `replicaCount`, or a
  DaemonSet when the answer is "one per node".
