# haproxy

A Helm chart for installing [HAProxy](https://www.haproxy.org/) community edition in Kubernetes — as
a Deployment, a StatefulSet or a DaemonSet.

HAProxy is a TCP and HTTP load balancer and reverse proxy: it takes connections, decides where they
go, and keeps deciding while backends come and go. This chart gives you the process, its
configuration, its health and metrics endpoint, and the Kubernetes objects around them — it does not
watch the API server and it writes no configuration for you. What HAProxy does is entirely up to the
configuration file you hand it.

| | |
|---|---|
| Chart | `oci://ghcr.io/willbrid/charts/haproxy` |
| Source | [charthouse](https://github.com/willbrid/charthouse/tree/main/charts/haproxy) |
| Container image | [`haproxy:latest`](https://hub.docker.com/_/haproxy) (Docker Hub, official image) |
| Upstream sources | [github.com/haproxy/haproxy](https://github.com/haproxy/haproxy) |
| Configuration manual | [haproxy.com/documentation/haproxy-configuration-manual/latest](https://www.haproxy.com/documentation/haproxy-configuration-manual/latest/) |
| Configuration tutorials | [haproxy.com/documentation/haproxy-configuration-tutorials](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/) |

---

## Contents

- [Container image](#container-image)
- [Prerequisites](#prerequisites)
- [Install](#install)
- [Example scenarios](#example-scenarios)
- [Configuration](#configuration)
  - [Choosing a workload kind](#choosing-a-workload-kind)
  - [Injecting the HAProxy configuration](#injecting-the-haproxy-configuration)
  - [Extra files: maps, error pages, Lua](#extra-files-maps-error-pages-lua)
  - [`command`, and why `-c` is not it](#command-and-why--c-is-not-it)
  - [Ports and service](#ports-and-service)
  - [Health, metrics and stats](#health-metrics-and-stats)
  - [Probes](#probes)
  - [Security context](#security-context)
  - [Host network](#host-network)
  - [Environment variables](#environment-variables)
  - [Volumes](#volumes)
  - [Per-pod storage (StatefulSet)](#per-pod-storage-statefulset)
  - [NetworkPolicy](#networkpolicy)
  - [TLS](#tls)
  - [Graceful shutdown and reloads](#graceful-shutdown-and-reloads)
  - [Availability: replicas, HPA, PDB](#availability-replicas-hpa-pdb)
- [Recipes](#recipes)
- [Values](#values)
- [CI scenarios](#ci-scenarios)
- [Known limitations](#known-limitations)

---

## Container image

This chart builds and hosts no image. It deploys the **official HAProxy image** published on Docker
Hub: **[hub.docker.com/_/haproxy](https://hub.docker.com/_/haproxy)** (`haproxy:latest`), built from
the sources at **[github.com/haproxy/haproxy](https://github.com/haproxy/haproxy)**.

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `haproxy` | Docker Hub official image |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |

Three properties of that image the chart relies on, and that a replacement image must also have:

- it runs as the unprivileged **`haproxy` user, uid 99 / gid 99** — which is why the default
  configuration binds 8080 and 8404 rather than 80 and 443;
- it is built with **`USE_PROMEX=1`**, so `http-request use-service prometheus-exporter` works with
  no sidecar and no extra exporter;
- its entrypoint script adds `-W -db` when the command starts with `haproxy` — which a Kubernetes
  `command:` bypasses, see [`command`](#command-and-why--c-is-not-it).

```yaml
image:
  repository: haproxy
  tag: "3.4"        # or "3.4-alpine", "3.4.3"
  pullPolicy: IfNotPresent
```

> **Pin a tag.** `latest` follows the newest stable branch: an upgrade of the chart, or simply a pod
> rescheduled onto a node with a fresher cache, can move you across HAProxy branches without any
> change on your side. Pin `image.tag` to a branch (`3.4`) or a patch release (`3.4.3`). The chart
> `appVersion` records the branch this chart is written against.

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
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy

# Pinned version, own configuration file, dedicated namespace
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 \
  --namespace edge --create-namespace \
  --set-file config=./haproxy.cfg \
  --values my-values.yaml
```

`my-values.yaml` only holds what you override; everything else falls back to
[`values.yaml`](values.yaml).

Inspect before installing:

```bash
helm show values oci://ghcr.io/willbrid/charts/haproxy    # all available values
helm template haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --values my-values.yaml                                 # rendered manifests
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --values my-values.yaml --dry-run --debug               # server-side validation
```

### Upgrade

```bash
helm upgrade haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 --namespace edge --set-file config=./haproxy.cfg
```

Changing the configuration rolls the pods: the workload carries a `checksum/config` annotation
computed from the rendered ConfigMap, and `checksum/configmap` / `checksum/secret` for the
environment variables. A new pod runs `haproxy -c` before it starts, so a configuration that does not
parse leaves the old pods serving instead of taking the service down.

### Uninstall

```bash
helm uninstall haproxy --namespace edge
```

> PVCs created from `volumeClaimTemplates` are **not** deleted with the release. Remove them
> explicitly when the state they hold is no longer wanted:
> `kubectl delete pvc -l app.kubernetes.io/instance=haproxy -n edge`.

### `helm test`

```bash
helm test haproxy --namespace edge
```

The test runs a small pod that calls the proxy over the network: the Service resolves, it has ready
endpoints, `/healthz` answers and the Prometheus exporter answers. It deliberately does not call the
traffic port — with no backend configured HAProxy answers `503` there, which is correct behaviour and
would fail the test for the wrong reason.

---

## Example scenarios

Complete values files, one per installation shape, in [`docs/`](docs/). Each page carries the values,
the install command and how to check the result.

| # | Scenario | What it covers |
|---|---|---|
| 1 | [Quickstart](docs/01-quickstart.md) | Default install, what the default configuration does, first requests, a throwaway nginx backend to proxy to |
| 2 | [In-cluster HTTP load balancer](docs/02-http-load-balancer.md) | Routing to real backends, host- and path-based rules, active health checks |
| 3 | [TLS termination](docs/03-tls-termination.md) | Certificates from a Secret, `bind ... ssl crt`, redirect and HSTS |
| 4 | [Edge proxy on the host network](docs/04-edge-daemonset.md) | DaemonSet, `hostNetwork`, `NET_BIND_SERVICE`, ports 80/443 on the node |
| 5 | [Prometheus and stats](docs/05-metrics-and-stats.md) | The built-in exporter, what to scrape, what to alert on |
| 6 | [Hardened deployment](docs/06-hardened.md) | Restricted Pod Security Standard, NetworkPolicy both ways, PDB, anti-affinity |

---

## Configuration

| Section | Description |
|---|---|
| `kind` | Workload type: `Deployment`, `StatefulSet` or `DaemonSet` |
| `replicaCount` | Number of pods (not for a DaemonSet) |
| `config`, `extraFiles`, `existingConfigMap` | The HAProxy configuration and the files next to it |
| `configMountPath`, `configFileName` | Where that configuration lands in the container |
| `command`, `args` | What the container runs |
| `configCheck` | `haproxy -c` init container guarding the start |
| `image` | Container image and pull policy |
| `service` | Ports published, and the container ports they map to |
| `livenessProbe`, `readinessProbe`, `startupProbe` | Health checks, on the `health` port |
| `podSecurityContext`, `securityContext` | Privileges — the defaults are already tight |
| `hostNetwork` | Host network, PID and IPC namespaces, and the DNS policy that goes with them |
| `configmap`, `secret`, `env`, `envFrom` | Environment variables, expanded as `${VAR}` in the configuration |
| `volumes`, `volumeMounts` | Extra volumes, whatever the kind — certificates live here |
| `volumeClaimTemplates` | Per-pod PersistentVolumeClaims (StatefulSet only) |
| `networkPolicy` | Traffic allowed to and from the proxy |
| `autoscaling`, `podDisruptionBudget` | HPA and disruption budget |
| `lifecycle`, `terminationGracePeriodSeconds` | Shutdown behaviour |
| `resources`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` | Scheduling and limits |

Incoherent combinations are rejected at render time rather than silently ignored: an unknown `kind`,
`volumeClaimTemplates` outside a StatefulSet, a claim without a size, a volume colliding with a claim
or with the reserved `config` name, a service enabled without a port, a port name over 15 characters,
autoscaling on a DaemonSet, a NetworkPolicy on hostNetwork pods, `config` and `existingConfigMap`
together, and a `command` whose `-f` flag does not point at the file the chart mounts.

### Choosing a workload kind

The pod is identical in the three cases — only the controller around it changes.

```yaml
kind: Deployment    # or StatefulSet, or DaemonSet
```

| Kind | Use it for | Comes with |
|------|-----------|------------|
| `Deployment` (default) | Interchangeable proxy replicas behind one Service — an in-cluster gateway, an egress proxy, an API front door | `replicaCount`, `deployment.strategy`, `autoscaling` |
| `StatefulSet` | State that must survive a restart on the same ordinal, and proxies addressable at a predictable name | `volumeClaimTemplates`, a headless service, `statefulSet.podManagementPolicy` |
| `DaemonSet` | One proxy per node — an edge proxy on `hostNetwork`, a per-node egress proxy | One pod per node; `replicaCount` does not apply |

A StatefulSet also gets a headless service `<fullname>-headless`, created whatever `service.enabled`
says, which is what gives each pod a stable name:

```
haproxy-0.haproxy-headless.edge.svc.cluster.local
haproxy-1.haproxy-headless.edge.svc.cluster.local
```

That is what a `peers` section needs to synchronise stick tables between instances, and what lets a
client stay pinned to one proxy.

### Injecting the HAProxy configuration

The configuration is rendered into the ConfigMap `<fullname>-config`, mounted **read-only** at
`configMountPath`, and loaded by the `-f` flag of `command`. Three ways to provide it:

```yaml
# 1. Inline in your values file
config: |
  global
      log stdout format raw local0 info
  defaults
      mode http
      timeout connect 5s
      timeout client  50s
      timeout server  50s
  frontend http_in
      bind *:8080
      default_backend app
  backend app
      server app1 app.default.svc.cluster.local:80 check
```

```bash
# 2. From a file on disk, without touching values.yaml — the usual way to keep
#    haproxy.cfg in its own file, with editor support and its own review history
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --set-file config=./haproxy.cfg
```

```yaml
# 3. From a ConfigMap you manage yourself (GitOps, a shared config, an operator)
config: ""
existingConfigMap: my-haproxy-config     # must hold a `haproxy.cfg` key
```

The content goes through Helm's `tpl`, so `{{ .Release.Namespace }}` and friends are resolved.
HAProxy's own syntax is untouched: its ACL braces are single (`if { path /metrics }`) and never
collide with Helm's `{{ }}`, and a `${VAR}` is expanded by HAProxy itself at startup, from the
environment — see [Environment variables](#environment-variables).

| Value | Default | Meaning |
|---|---|---|
| `config` | the default configuration below | Content of the configuration file |
| `configMountPath` | `/usr/local/etc/haproxy` | Directory the ConfigMap is mounted into |
| `configFileName` | `haproxy.cfg` | File name inside it |
| `existingConfigMap` | `""` | Use a ConfigMap the chart does not manage. Mutually exclusive with `config` |
| `extraFiles` | `{}` | Additional files in the same directory |

`configMountPath` + `configFileName` is the path `command` must load. Change one without the other
and the chart stops at render time rather than handing you a crash loop:

```
haproxy: command does not load the configuration the chart mounts — expected the flags
`-f /etc/haproxy/haproxy.cfg` (configMountPath + configFileName), got [...]
```

> **Mounting a directory hides what the image put there.** `/usr/local/etc/haproxy` holds an
> `errors/` directory of default error pages in the official image, and the ConfigMap mount shadows
> it. If you reference those pages (`errorfile 503 /usr/local/etc/haproxy/errors/503.http`), mount
> the configuration one level down instead — `configMountPath: /usr/local/etc/haproxy/conf`, with the
> matching `-f` in `command` and `configCheck.command`.

> **A `server` hostname must resolve when HAProxy starts.** It refuses to start otherwise —
> `could not resolve address 'app.default.svc.cluster.local'` — and so does the `config-check` init
> container, which means a proxy installed before its backend Service exists never comes up. Add
> `init-addr none` to the `server` line (or `init-addr last,libc,none`) to let it start with the
> server marked down, and a `resolvers` section to pick the address up later.

**What the default configuration does.** It is deliberately a working skeleton with nothing behind
it: a `health` frontend on 8404 (`/healthz`, `/metrics`, `/stats`), a traffic frontend on 8080, and
an empty `backend app`. Requests to the traffic port answer `503` until you add servers — that is the
one thing you have to change.

### Extra files: maps, error pages, Lua

`extraFiles` renders additional keys into the same ConfigMap, so they land next to the configuration
and are referenced by absolute path:

```yaml
extraFiles:
  hosts.map: |
    api.example.com   api_backend
    www.example.com   www_backend
  503.http: |
    HTTP/1.1 503 Service Unavailable
    Content-Type: text/plain
    Connection: close

    Backend unavailable.

config: |
  defaults
      errorfile 503 /usr/local/etc/haproxy/503.http
  frontend http_in
      bind *:8080
      use_backend %[req.hdr(host),lower,word(1,:),map(/usr/local/etc/haproxy/hosts.map,api_backend)]
```

Each content goes through `tpl` like the configuration. Keep it to configuration data: a ConfigMap is
readable by anybody with `get` on the namespace and is capped at 1 MiB — certificates and secrets go
through a Secret, and large static assets do not belong in a proxy at all.

### `command`, and why `-c` is not it

```yaml
command:
  - "haproxy"
  - "-W"        # master-worker: a master supervises the workers, needed for SIGUSR2 reloads
  - "-db"       # stay in the foreground, so the container lives as long as HAProxy
  - "-f"
  - "/usr/local/etc/haproxy/haproxy.cfg"
args: []
```

`-W -db` are not optional decoration. The official image entrypoint adds them itself, but a
Kubernetes `command:` **replaces the image ENTRYPOINT**, so the entrypoint script never runs and the
flags have to be spelled out here. Without `-W` there is no master process and no reload; without
`-db` HAProxy may background itself and the container exits.

`haproxy -c -f <file>` is the **configuration check**: it parses, reports, and exits. A container
whose `command` is that starts, succeeds, exits, gets restarted, and ends in `CrashLoopBackOff` — it
is not a way to run the proxy. The chart runs it where it is useful, as an init container in front of
HAProxy:

```yaml
configCheck:
  enabled: true
  command: ["haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
  resources: {}
```

A configuration that does not parse then produces a pod stuck in `Init` with the parser error in its
logs — and during an upgrade, a new pod that never becomes ready while the old ones keep serving:

```bash
kubectl logs <pod> -c config-check
```

The init container gets the same configuration, the same volumes and the same environment as HAProxy
itself, or it would validate something other than what runs. Set `configCheck.enabled: false` to skip
it — the only reason to is a configuration that can only be checked at runtime.

### Ports and service

One list drives both sides: each `service.ports` entry declares a container port **and** a service
port. Container ports are declared even when `service.enabled` is `false`, so a probe can target them
by name and a hostNetwork pod can mirror them into `hostPort`.

```yaml
service:
  enabled: true
  type: ClusterIP          # or NodePort, LoadBalancer
  annotations: {}
  externalTrafficPolicy: ""    # Local preserves the client address (NodePort/LoadBalancer)
  ports:
    - name: http
      port: 80             # what clients call
      targetPort: 8080     # what HAProxy binds — must match a `bind` line
      protocol: TCP
    - name: health
      port: 8404
      targetPort: 8404
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Unique, 15 characters max (Kubernetes constraint); what probes reference |
| `port` | yes | Port exposed by the service |
| `targetPort` | no | Container port; defaults to the port name, which resolves to `port` |
| `protocol` | no | `TCP` (default) or `UDP` |
| `nodePort` | no | Honoured by `type: NodePort` and `LoadBalancer` only |

The container ports are **8080 and 8404, not 80 and 443**, because the process runs as uid 99 with
every capability dropped. The Service remaps them, so clients still use the standard ports and
nothing is gained by binding low ports inside the pod. The exception is
[`hostNetwork`](#host-network), where there is no Service to remap anything.

Every port must have a matching `bind` line in the configuration — the chart cannot know what your
configuration listens on, and a declared port nothing binds is a port whose probe fails.

### Health, metrics and stats

The default configuration dedicates a frontend to it, on the `health` port:

```
frontend health
    bind *:8404
    mode http
    http-request set-log-level silent
    monitor-uri /healthz
    http-request use-service prometheus-exporter if { path /metrics }
    stats enable
    stats uri /stats
    stats refresh 10s
```

| Endpoint | Answers |
|---|---|
| `/healthz` | `200` while HAProxy runs — what the probes call |
| `/metrics` | The Prometheus exporter built into the image (`USE_PROMEX=1`), no sidecar |
| `/stats` | The HTML statistics page: frontends, backends, per-server state and counters |

```bash
kubectl port-forward -n edge svc/haproxy 8404:8404
curl http://127.0.0.1:8404/healthz
curl http://127.0.0.1:8404/metrics
open http://127.0.0.1:8404/stats
```

This port exposes the whole internal state of the proxy — every backend, every server, every counter.
Keep it away from the traffic path: restrict it with a [NetworkPolicy](#networkpolicy), or put the
stats page behind `stats auth admin:${STATS_PASSWORD}` with the password coming from `secret`. Do not
simply delete the entry from `service.ports` — that removes the container port the probes target with
it. Publishing a separate Service for the health port, if you want it off the public one, is the
cleaner split.

Scraping with the Prometheus Operator means a `ServiceMonitor`, which this chart does not create
(it would require the CRD). Write it yourself against the `health` port, or use pod annotations with
a Prometheus configured for pod discovery:

```yaml
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8404"
  prometheus.io/path: "/metrics"
```

### Probes

```yaml
livenessProbe:
  httpGet: {path: /healthz, port: health}
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet: {path: /healthz, port: health}
  initialDelaySeconds: 2
  periodSeconds: 5
startupProbe: {}
```

Both target the `health` port by **name**, so they follow whatever number you give it.

They deliberately do not probe the traffic port. A proxy whose backends are all down still answers
`503` correctly — restarting it would fix nothing, and taking it out of the endpoints would only move
the error. What the probes must detect is HAProxy itself being gone, and that is what `monitor-uri`
reports. If you do want readiness to follow backend availability, `monitor fail if <condition>` in
the health frontend is the HAProxy-side way to express it.

Change `config` in a way that removes `monitor-uri /healthz`, or remove the `health` port, and you
must change the probes with it.

### Security context

The defaults are already the tight ones, and they are what the CI installs:

```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 99          # the `haproxy` user of the official image
  runAsGroup: 99
  fsGroup: 99            # makes mounted volumes, PVCs included, writable by it
  seccompProfile:
    type: RuntimeDefault

securityContext:
  capabilities:
    drop: [ALL]
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
```

HAProxy runs under this: it reads its configuration, binds its ports and logs to stdout, and writes
nothing to its filesystem. This passes the `restricted` Pod Security Standard.

| You want | Add |
|---|---|
| Bind 80/443 inside the container | `capabilities.add: [NET_BIND_SERVICE]` — only worth it with `hostNetwork`; otherwise remap in the Service |
| A `stats socket` on a UNIX path, `server-state-file`, peers persistence, ACME | Somewhere writable: an `emptyDir` in `volumes`, or a `volumeClaimTemplates` entry — not `readOnlyRootFilesystem: false` |
| Transparent proxying (`source ... usesrc`) | `capabilities.add: [NET_ADMIN]`, and a kernel that allows it |

### Host network

```yaml
hostNetwork:
  enabled: false     # own network namespace and pod IP
  dnsPolicy: ""      # derived: ClusterFirstWithHostNet when enabled, ClusterFirst otherwise
  hostPID: false
  hostIPC: false
```

With `enabled: true` the pod shares the network namespace of its node: the ports HAProxy binds are
opened **on the node itself**, which is how an edge proxy takes traffic arriving at the node address
without a Service in front of it. Three consequences, and what the chart does about each:

- **DNS.** A hostNetwork pod keeping the default `ClusterFirst` falls back to the node resolver and
  stops resolving `*.svc.cluster.local` — every backend addressed by its service name breaks. The
  chart derives `ClusterFirstWithHostNet`; override with `hostNetwork.dnsPolicy`.
- **Ports.** A container port is a node port. The chart mirrors each `service.ports` entry into a
  `hostPort`, so a conflict shows up at scheduling time instead of at runtime. Two pods cannot share
  a node port: a hostNetwork DaemonSet is one HAProxy per node, and nothing else on the node may hold
  its ports. Binding 80 and 443 there needs `NET_BIND_SERVICE`.
- **NetworkPolicies do not apply.** See below.

### Environment variables

Four ways in, meant for different things:

```yaml
# Non-sensitive — rendered into the ConfigMap <fullname>, pulled in with envFrom
configmap:
  BACKEND_HOST: "api.default.svc.cluster.local"
  BACKEND_PORT: "8080"

# Sensitive — rendered into the Secret <fullname>, pulled in with envFrom
secret:
  STATS_PASSWORD: "changeme"

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
```

They matter more here than on most workloads: **HAProxy expands `${VAR}` in its configuration file at
startup**, which is how one configuration file serves several environments.

```
backend app
    server app1 ${BACKEND_HOST}:${BACKEND_PORT} check
```

The `config-check` init container receives the same variables, so the check validates the
configuration that will actually run. The ConfigMap and the Secret are created only when their map is
non-empty, are named after the release (`<fullname>`), and changing either rolls the pods through the
checksum annotations.

### Volumes

`volumes` and `volumeMounts` are passed through as written, for every kind. The chart already mounts
the configuration as a volume named `config`; that name is reserved and reusing it is rejected.

```yaml
volumes:
  - name: certs
    secret:
      secretName: haproxy-tls
  - name: run
    emptyDir: {}

volumeMounts:
  - name: certs
    mountPath: /etc/haproxy/certs
    readOnly: true
  - name: run
    mountPath: /run/haproxy
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
  - name: state
    size: 1Gi
    mountPath: /var/lib/haproxy/state    # mounted for you
    accessModes: [ReadWriteOnce]
    storageClassName: standard
  - name: spool
    size: 1Gi
    mountPath: /var/spool/haproxy
    enabled: false                        # declared, but nothing is created
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Volume name and PVC name prefix |
| `size` | yes | Requested capacity |
| `enabled` | no (`true`) | `false` keeps the entry in the file and creates nothing |
| `mountPath` | no | Mounts the volume there. Left out, add a `volumeMounts` entry with the same name |
| `subPath`, `readOnly` | no | Refine that mount |
| `accessModes` | no (`[ReadWriteOnce]`) | |
| `storageClassName` | no | Defaults to the cluster default StorageClass |
| `volumeMode`, `selector`, `labels`, `annotations` | no | |

What a proxy puts there: the `server-state-file`, so a restarted pod picks its servers back up in the
state it left them instead of starting a cold health-check storm.

```yaml
config: |
  global
      server-state-file /var/lib/haproxy/state/global
  defaults
      load-server-state-from-file global
```

`podSecurityContext.fsGroup: 99` is what makes that volume writable by HAProxy — without it the mount
belongs to root and the write fails, `readOnlyRootFilesystem` or not.

### NetworkPolicy

```yaml
networkPolicy:
  enabled: true
```

That alone renders a policy governing **both directions**: nothing in, nothing out except the cluster
DNS (`allowDNS: true`). On a proxy that means no client reaches it and every backend answers 503, so
both directions are normally filled in:

```yaml
networkPolicy:
  enabled: true
  allowDNS: true
  ingress:
    # traffic from the whole cluster, on the traffic port only
    - from:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 8080
    # metrics and stats, monitoring namespace only
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8404
  egress:
    # the backends this proxy is allowed to reach, and nothing else
    - to:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: my-app
      ports:
        - protocol: TCP
          port: 8080
```

| Value | Default | Meaning |
|---|---|---|
| `policyTypes` | `[]` → `[Ingress, Egress]` | A direction absent from this list is not restricted at all. Set it explicitly to govern only one |
| `allowDNS` | `true` | Egress rule to the cluster DNS, added on top of `egress`. Without it, backends addressed by name stop resolving |
| `dns.namespace`, `dns.podSelector`, `dns.ports` | CoreDNS in `kube-system` | Where the DNS service is |
| `ingress`, `egress` | `[]` | Rules in the format of the NetworkPolicy spec |
| `annotations`, `labels` | `{}` | On the policy object itself |
| `allowHostNetwork` | `false` | See below |

Two things to know before relying on it:

- **The CNI enforces it, not Kubernetes.** Under a plugin that ignores NetworkPolicies the object is
  created and restricts nothing, silently. Calico, Cilium, Antrea, Weave and recent kindnet builds
  enforce them. Rather than trust a list, check your own cluster: install with the policy and try to
  reach something it forbids.
- **It never applies to hostNetwork pods.** A NetworkPolicy selects pods on the pod network, so with
  `hostNetwork.enabled: true` the policy would exist and do nothing. The chart fails the render rather
  than handing you that false sense of containment; `networkPolicy.allowHostNetwork: true` creates it
  anyway.

Note that the kubelet probes a pod from the node, and node traffic is not subject to NetworkPolicies:
an ingress-closed policy does not break the probes.

### TLS

The chart mounts no certificate of its own. HAProxy wants a **PEM file holding the private key and
the certificate chain concatenated**, which is not the shape of a `kubernetes.io/tls` Secret (two
separate keys, `tls.crt` and `tls.key`). Two ways round it:

```yaml
# 1. A generic Secret holding one combined PEM, created by you or by your certificate
#    tooling (cert-manager can be told to add a `tls-combined.pem` key).
volumes:
  - name: certs
    secret:
      secretName: haproxy-tls        # data: tls.pem = key + fullchain
volumeMounts:
  - name: certs
    mountPath: /etc/haproxy/certs
    readOnly: true

config: |
  frontend https_in
      bind *:8443 ssl crt /etc/haproxy/certs/tls.pem
      mode http
      http-response set-header Strict-Transport-Security "max-age=31536000"
      default_backend app
```

```yaml
# 2. Point `crt` at a directory: HAProxy loads every PEM it finds, which is how you
#    serve several certificates and let SNI pick.
#      bind *:8443 ssl crt /etc/haproxy/certs/
```

Add the matching `service.ports` entry (`{name: https, port: 443, targetPort: 8443}`). Certificate
renewal writes a new Secret; the pods do not notice on their own — restart the workload, or reload
HAProxy.

### Graceful shutdown and reloads

Two different things, both worth setting up on a proxy that matters.

**Rollouts.** A pod is removed from the Service endpoints and sent `SIGTERM` at the same moment, and
the endpoint change takes about a second to reach every node. Requests sent in that window hit a
proxy that is already stopping. A `preStop` sleep covers it:

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
terminationGracePeriodSeconds: 30     # must exceed the sleep, plus the longest request
```

HAProxy stops on `SIGTERM` without draining. `hard-stop-after 30s` in the `global` section bounds how
long a soft stop may take when you trigger one; `terminationGracePeriodSeconds` must be larger than
the sum of the preStop sleep and that bound, or the kubelet kills the process mid-request.

**Configuration changes.** `helm upgrade` with a changed configuration rolls the pods, because the
workload carries a checksum of the ConfigMap. That is a full rolling restart, which is correct and
safe. HAProxy's own `SIGUSR2` reload — the reason `-W` is in the command — is the alternative when
you want zero connection loss on a busy proxy:

```bash
kubectl exec -n edge deploy/haproxy -- kill -USR2 1
```

Beware that this reloads from the file the pod already has: it is only useful once the ConfigMap
content has propagated to the pod (a mounted ConfigMap updates within a minute or so), and a pod
recreated afterwards starts from the ConfigMap anyway. Prefer the rolling restart unless you have
measured that you cannot afford it.

### Availability: replicas, HPA, PDB

`replicaCount` defaults to `2`, not `1`: a single-pod proxy makes every rollout and every node drain
an outage. Spread them across nodes, or two replicas on one node fall together with it:

```yaml
replicaCount: 3
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: haproxy

deployment:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0      # keep serving during the rollout

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1          # a drain moves one replica at a time
```

With `autoscaling.enabled: true` the chart leaves `replicas` out of the workload so the HPA owns it,
and rejects the combination with a DaemonSet. Keep `minReplicas` at two or more, and remember CPU is
a poor proxy for proxy load — connection count and latency describe it better, through custom
metrics.

---

## Recipes

**An in-cluster HTTP load balancer in front of a Service.**

```yaml
config: |
  global
      log stdout format raw local0 info
  defaults
      log global
      mode http
      option httplog
      timeout connect 5s
      timeout client  50s
      timeout server  50s
  frontend health
      bind *:8404
      monitor-uri /healthz
      http-request use-service prometheus-exporter if { path /metrics }
  frontend http_in
      bind *:8080
      default_backend app
  backend app
      balance roundrobin
      option httpchk GET /healthz
      # a headless service resolves to the pod IPs: HAProxy balances, not kube-proxy
      server-template app 3 app-headless.default.svc.cluster.local:8080 check resolvers kube
  resolvers kube
      parse-resolv-conf
      hold valid 10s
```

**An edge proxy on every node, taking traffic on ports 80 and 443.**

```yaml
kind: DaemonSet
hostNetwork:
  enabled: true
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]      # required to bind below 1024
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
service:
  enabled: false                  # reached at the node address
  ports:
    - {name: http, port: 80, targetPort: 80}
    - {name: https, port: 443, targetPort: 443}
    - {name: health, port: 8404, targetPort: 8404}
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
```

**A contained proxy: it may be reached from the cluster, and may reach exactly one backend.**

```yaml
networkPolicy:
  enabled: true
  ingress:
    - from: [{namespaceSelector: {}}]
      ports: [{protocol: TCP, port: 8080}]
  egress:
    - to: [{podSelector: {matchLabels: {app.kubernetes.io/name: my-app}}}]
      ports: [{protocol: TCP, port: 8080}]
```

**Two proxies with stable names, keeping their server state across restarts.**

```yaml
kind: StatefulSet
replicaCount: 2
statefulSet:
  podManagementPolicy: Parallel
volumeClaimTemplates:
  - name: state
    size: 1Gi
    mountPath: /var/lib/haproxy/state
config: |
  global
      server-state-file /var/lib/haproxy/state/global
  defaults
      load-server-state-from-file global
      mode http
      timeout connect 5s
      timeout client 50s
      timeout server 50s
  frontend health
      bind *:8404
      monitor-uri /healthz
  frontend http_in
      bind *:8080
      default_backend app
  backend app
      server app1 app.default.svc.cluster.local:80 check
```

---

## Values

### Workload

| Value | Default | Description |
|---|---|---|
| `kind` | `Deployment` | `Deployment`, `StatefulSet` or `DaemonSet` |
| `replicaCount` | `2` | Number of pods; ignored by `DaemonSet` and by an enabled HPA |
| `deployment.strategy` | `{}` | Deployment update strategy |
| `statefulSet.podManagementPolicy` | `OrderedReady` | `Parallel` starts every pod at once |
| `statefulSet.updateStrategy` | `{}` | |
| `daemonSet.updateStrategy` | `{}` | |
| `terminationGracePeriodSeconds` | `30` | |
| `priorityClassName` | `""` | |

### Container

| Value | Default | Description |
|---|---|---|
| `image.repository` | `haproxy` | |
| `image.tag` | `latest` | Pin it |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `command` | `["haproxy","-W","-db","-f","/usr/local/etc/haproxy/haproxy.cfg"]` | |
| `args` | `[]` | |
| `configCheck.enabled` | `true` | `haproxy -c` init container |
| `configCheck.command` | `["haproxy","-c","-f","/usr/local/etc/haproxy/haproxy.cfg"]` | |
| `configCheck.resources` | `{}` | |
| `resources` | `{}` | |
| `livenessProbe`, `readinessProbe` | `httpGet /healthz` on the `health` port | |
| `startupProbe` | `{}` | |
| `lifecycle` | `{}` | A `preStop` sleep belongs here |

### Configuration

| Value | Default | Description |
|---|---|---|
| `config` | working skeleton | HAProxy configuration; `--set-file config=./haproxy.cfg` also works |
| `configMountPath` | `/usr/local/etc/haproxy` | |
| `configFileName` | `haproxy.cfg` | |
| `extraFiles` | `{}` | Maps, error pages, Lua — same ConfigMap, same directory |
| `existingConfigMap` | `""` | Bring your own ConfigMap; mutually exclusive with `config` |

### Security and host access

| Value | Default | Description |
|---|---|---|
| `podSecurityContext` | uid/gid 99, `runAsNonRoot`, `fsGroup`, `RuntimeDefault` | |
| `securityContext` | drops `ALL`, no escalation, read-only root | |
| `hostNetwork.enabled` | `false` | Ports bound on the node |
| `hostNetwork.dnsPolicy` | `""` | Derived: `ClusterFirstWithHostNet` / `ClusterFirst` |
| `hostNetwork.hostPID`, `hostNetwork.hostIPC` | `false` | |
| `serviceAccount.create` | `true` | |
| `serviceAccount.automount` | `false` | HAProxy never calls the API server |
| `serviceAccount.annotations`, `serviceAccount.name` | `{}`, `""` | |

### Environment, storage, network

| Value | Default | Description |
|---|---|---|
| `configmap` | `{}` | Non-sensitive env vars → ConfigMap `<fullname>` |
| `secret` | `{}` | Sensitive env vars → Secret `<fullname>` |
| `env`, `envFrom` | `[]` | Individual variables; pre-existing objects |
| `volumes`, `volumeMounts` | `[]` | Extra volumes, any kind. `config` is reserved |
| `volumeClaimTemplates` | `[]` | Per-pod PVCs, StatefulSet only |
| `service.enabled` | `true` | |
| `service.type` | `ClusterIP` | |
| `service.ports` | `http` 80→8080, `health` 8404 | Drives the container ports too |
| `service.annotations`, `externalTrafficPolicy`, `loadBalancerIP`, `loadBalancerSourceRanges` | empty | |
| `networkPolicy.enabled` | `false` | |
| `networkPolicy.allowDNS` | `true` | |
| `networkPolicy.policyTypes`, `ingress`, `egress` | `[]` | |

### Availability and scheduling

| Value | Default |
|---|---|
| `autoscaling.enabled` | `false` (`minReplicas` 2, `maxReplicas` 10, CPU 80%) |
| `podDisruptionBudget.enabled` | `false` (`maxUnavailable: 1`) |
| `nodeSelector`, `affinity` | `{}` |
| `tolerations`, `topologySpreadConstraints` | `[]` |
| `podAnnotations`, `podLabels` | `{}` |
| `nameOverride`, `fullnameOverride` | `haproxy` |

---

## CI scenarios

[`ci/`](ci/) holds the values files chart-testing installs on a Kind cluster. Each one covers a
distinct shape of the chart, and each configuration is a valid HAProxy configuration — the
`config-check` init container fails the install otherwise, which makes every run a syntax test too.

| Scenario | Covers |
|---|---|
| [`scenario-basic-values.yaml`](ci/scenario-basic-values.yaml) | Deployment, two replicas, config check, a backend proxying to the health frontend, `${VAR}` from a ConfigMap, Secret, downward API, PDB, preStop hook, default security context |
| [`scenario-statefulset-values.yaml`](ci/scenario-statefulset-values.yaml) | StatefulSet, headless service, two `volumeClaimTemplates` (one disabled), `server-state-file` on the PVC, `fsGroup` making it writable |
| [`scenario-daemonset-hostnetwork-values.yaml`](ci/scenario-daemonset-hostnetwork-values.yaml) | DaemonSet on `hostNetwork`, derived `ClusterFirstWithHostNet`, `hostPort` mirroring, no Service, control-plane tolerations, `replicaCount` ignored |
| [`scenario-networkpolicy-values.yaml`](ci/scenario-networkpolicy-values.yaml) | NetworkPolicy with both directions governed, DNS rule, ingress split between traffic and health ports, egress rules |
| [`scenario-extra-files-values.yaml`](ci/scenario-extra-files-values.yaml) | `extraFiles` (map file, custom error page), alternate `configMountPath` keeping the image `errors/` visible, HPA owning the replicas, PDB, topology spread |

The NetworkPolicy scenario proves the object is created, valid and selecting the right pods, and that
the helm test still reaches the health port through it. Whether traffic is actually blocked depends
on the CNI: recent kindnet builds enforce policies, older ones ignore them and the run simply proves
less.

---

## Known limitations

- **The chart does not watch Kubernetes.** It renders a static configuration file. Backends change as
  pods come and go; a `server` line pointing at a Service name follows the Service VIP, and
  `server-template` with a `resolvers` section follows a headless service's records — but nothing
  here rewrites the configuration when the cluster changes. If you want an Ingress controller, use
  the [HAProxy Kubernetes Ingress Controller](https://github.com/haproxytech/kubernetes-ingress),
  which is a different product with a different chart.
- **No ServiceMonitor and no Ingress object.** The first needs the Prometheus Operator CRDs, the
  second puts an ingress controller in front of a proxy. Both are yours to add.
- **`hostNetwork` and NetworkPolicies do not mix**, and the chart refuses the combination by default.
- **A reload is not a config change.** `helm upgrade` rolls the pods; `SIGUSR2` reloads from the file
  already in the pod. They are not interchangeable — see
  [Graceful shutdown and reloads](#graceful-shutdown-and-reloads).
- **TLS certificates need the HAProxy shape**, key and chain in one PEM, which a
  `kubernetes.io/tls` Secret is not. See [TLS](#tls).
- **No RBAC is created.** The chart mounts no API token (`serviceAccount.automount: false`) and
  grants nothing.
