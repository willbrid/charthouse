# fluentbit

A Helm chart for installing [Fluent Bit](https://fluentbit.io/) in Kubernetes — as a Deployment, a
StatefulSet or a DaemonSet.

| | |
|---|---|
| Chart | `oci://ghcr.io/willbrid/charts/fluentbit` |
| Source | [charthouse](https://github.com/willbrid/charthouse/tree/main/charts/fluentbit) |
| Container image | [`fluent/fluent-bit`](https://hub.docker.com/r/fluent/fluent-bit) (Docker Hub) |

---

## Container image

This chart builds and hosts no image. It deploys the official **Fluent Bit** image published on
Docker Hub: **[hub.docker.com/r/fluent/fluent-bit](https://hub.docker.com/r/fluent/fluent-bit)**.

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `fluent/fluent-bit` | Docker Hub repository |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |

> **Pin a tag.** `latest` is convenient for a first try but is not reproducible: two pods of the same
> release can end up on two different builds. Set `image.tag` to an explicit version for anything
> beyond a test.

```yaml
image:
  repository: fluent/fluent-bit
  tag: "5.0.9"
  pullPolicy: IfNotPresent
```

`image.repository` also accepts a private mirror of that same image, combined with
`imagePullSecrets` when the registry requires credentials.

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
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit

# Pinned version, own values, dedicated namespace
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging --create-namespace \
  --values my-values.yaml
```

`my-values.yaml` only holds what you override; everything else falls back to
[`values.yaml`](values.yaml).

Inspect before installing:

```bash
helm show values oci://ghcr.io/willbrid/charts/fluentbit    # all available values
helm template fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --values my-values.yaml                                   # rendered manifests
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --values my-values.yaml --dry-run --debug                 # server-side validation
```

## Upgrade

```bash
helm upgrade fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging \
  --values my-values.yaml
```

A configuration change alone restarts the pods: the workload carries a `checksum/config`
annotation computed from the rendered configuration.

## Uninstall

```bash
helm uninstall fluentbit --namespace logging
```

> PVCs created from `volumeClaimTemplates` are **not** deleted with the release — Kubernetes keeps
> them so a re-install can pick the buffered data back up. Remove them explicitly when they are no
> longer wanted: `kubectl delete pvc -l app.kubernetes.io/instance=fluentbit -n logging`.

---

## Configuration

| Section | Description |
|---|---|
| `kind` | Workload type: `Deployment`, `StatefulSet` or `DaemonSet` |
| `replicaCount`, `autoscaling` | Number of pods, fixed or driven by an HPA (not for a DaemonSet) |
| `volumeClaimTemplates` | Per-pod PersistentVolumeClaims (StatefulSet only) |
| `image` | Container image and pull policy |
| `command`, `configMountPath`, `configFileName` | Entrypoint and where/how the configuration is read |
| `config` | The Fluent Bit configuration itself, inline or through `--set-file` |
| `parsers` | Optional custom parsers file, mounted next to the configuration |
| `service` | Service type and the list of exposed ports |
| `secret` | Sensitive env vars (output API keys, passwords) — stored in a Secret |
| `configmap` | Non-sensitive env vars (endpoints, hostnames) — stored in a ConfigMap |
| `ingress`, `httpRoute` | Optional external exposure (Ingress or Gateway API) |
| `livenessProbe`, `readinessProbe` | Health checks against the HTTP monitoring server |
| `volumes`, `volumeMounts` | Extra volumes (host paths, TLS material, …) |
| `resources`, `nodeSelector`, `tolerations`, `affinity` | Scheduling and limits |

### Choosing a workload kind

The pod is identical in the three cases — only the controller around it changes.

```yaml
kind: Deployment    # or StatefulSet, or DaemonSet
```

| Kind | Use it for | Comes with |
|------|-----------|------------|
| `Deployment` (default) | An aggregator receiving logs over the network (`forward`, `http`, `tcp` inputs) | `replicaCount`, `autoscaling` |
| `StatefulSet` | A filesystem buffer that must survive a restart | `volumeClaimTemplates`, a headless service giving each pod a stable DNS name, `statefulSet.podManagementPolicy` |
| `DaemonSet` | Collecting the logs of the nodes themselves (`tail` on `/var/log`) | One pod per node; `replicaCount` and `autoscaling` do not apply |

Incoherent combinations are rejected at render time rather than silently ignored —
`volumeClaimTemplates` outside a StatefulSet, `autoscaling.enabled` with a DaemonSet, an unknown
`kind`.

### Injecting the Fluent Bit configuration

`configFileName` selects the parsing mode of Fluent Bit, and the chart passes the matching file to
the binary as `-c <configMountPath>/<configFileName>`:

| `configFileName` | Mode | `config` accepts |
|---|---|---|
| `fluent-bit.conf` (default) | classic | a string |
| `fluent-bit.yaml` | YAML | a string **or** a YAML mapping |

Inline, in your values file:

```yaml
config: |
  [SERVICE]
      flush         1
      http_server   On
      http_listen   0.0.0.0
      http_port     2020
      health_check  On

  [INPUT]
      name          forward
      listen        0.0.0.0
      port          24224

  [OUTPUT]
      name          stdout
      match         *
```

Or from an existing file, without touching the values at all:

```bash
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --set-file config=./fluent-bit.conf
```

The content goes through `tpl`, so Helm expressions such as `{{ .Release.Namespace }}` are resolved,
while the Fluent Bit `${VAR}` placeholders are left untouched — that is what makes the `secret` and
`configmap` env vars usable from the configuration.

> **Careful with `configMountPath`.** Mounting over `/fluent-bit/etc` (the default) hides the files
> the image ships in that directory, `parsers.conf` in particular. Set `configMountPath` to
> `/fluent-bit/etc/conf` to keep them, and reference them by absolute path.

### Custom parsers (optional)

Nothing is mounted while `parsers.content` is empty. Fill it in, and the file lands next to the
configuration file, in the same ConfigMap:

```yaml
parsers:
  fileName: custom_parsers.conf
  content: |
    [PARSER]
        Name        custom_json
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S %z

config: |
  [SERVICE]
      parsers_file  custom_parsers.conf   # relative to the configuration file
  ...
```

`--set-file parsers.content=./custom_parsers.conf` works here too.

### Multiple ports

Each `service.ports` entry drives both the Service port and the matching container port. Declaring
a port is not enough — the matching `[INPUT]` must exist in the configuration.

```yaml
service:
  type: ClusterIP
  ports:
    - name: health           # HTTP monitoring server, targeted by the probes
      port: 2020
      targetPort: 2020
      protocol: TCP
    - name: forward
      port: 24224
      targetPort: 24224
      protocol: TCP
    - name: syslog
      port: 5140
      targetPort: 5140
      protocol: UDP
```

Names are unique and limited to 15 characters (a Kubernetes constraint), and the first entry is the
default backend of the Ingress and the HTTPRoute — both of which can also target another entry by
name or number through their `port` value.

### Probes

Both probes hit the HTTP monitoring server, which `http_server On` enables. The two paths are not
interchangeable:

```yaml
livenessProbe:
  httpGet:
    path: /                  # only proves the HTTP server answers
    port: health
readinessProbe:
  httpGet:
    path: /api/v1/health     # the health status computed by Fluent Bit
    port: health
```

`/api/v1/health` answers **404 unless `health_check On` is set** in the `[SERVICE]` section — a
readiness probe pointing at it without that setting never passes.

### Environment variables

Two sections, injected with `envFrom` and referenced from the configuration as `${VAR}`. Each
resource is created only when its section is non-empty.

```yaml
secret:                      # base64-encoded, into a Secret
  ELASTICSEARCH_PASSWORD: "changeme"

configmap:                   # plain text, into a ConfigMap
  ELASTICSEARCH_HOST: "elasticsearch.logging.svc.cluster.local"
```

> `secret` values sit in plain text in your values file and in the release. For real credentials,
> prefer an external secret manager and reference the Secret it produces.

### Per-pod storage (StatefulSet)

Each entry produces one PVC per pod, named `<entry>-<statefulset>-<ordinal>`. Declaring an entry
does not mount it — add the matching `volumeMounts` entry:

```yaml
kind: StatefulSet
replicaCount: 2

volumeClaimTemplates:
  - name: buffer
    size: 2Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: "standard"

volumeMounts:
  - name: buffer
    mountPath: /var/log/flb-storage

config: |
  [SERVICE]
      storage.path  /var/log/flb-storage/
      storage.sync  normal
  [INPUT]
      name          forward
      storage.type  filesystem
  ...
```

The chart also creates a headless service, so each pod is reachable at
`<release>-<ordinal>.<release>-headless:<port>` — for example
`fluentbit-0.fluentbit-headless:2020`.

### Node log collection (DaemonSet)

```yaml
kind: DaemonSet

volumes:
  - name: varlog
    hostPath:
      path: /var/log
  - name: state          # writable location for the tail position database
    emptyDir: {}

volumeMounts:
  - name: varlog
    mountPath: /var/log
    readOnly: true
  - name: state
    mountPath: /var/flb-state

tolerations:             # cover the control-plane nodes too
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

config: |
  [INPUT]
      name          tail
      path          /var/log/containers/*.log
      # Without this, Fluent Bit tails its own log while writing to stdout and
      # re-ingests every record, growing the file exponentially.
      exclude_path  /var/log/containers/*fluentbit*.log
      db            /var/flb-state/flb_kube.db
  ...
```

The position database (`db`) must live on a **writable** path: the host log directories are mounted
read-only, and Fluent Bit refuses to start when it cannot create that file.

---

## Reference

- All values, documented inline: [`values.yaml`](values.yaml)
- Working configurations covering each feature: [`ci/`](ci/) — one file per scenario, exercised by
  the CI on a real cluster
- Fluent Bit configuration reference: <https://docs.fluentbit.io/manual/administration/configuring-fluent-bit>
