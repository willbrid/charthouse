# otelcollector

A Helm chart for installing the [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
(**contrib** distribution) in Kubernetes.

| | |
|---|---|
| Chart | `oci://ghcr.io/willbrid/charts/otelcollector` |
| Source | [charthouse](https://github.com/willbrid/charthouse/tree/main/charts/otelcollector) |
| Container image | [`otel/opentelemetry-collector-contrib`](https://hub.docker.com/r/otel/opentelemetry-collector-contrib) (Docker Hub) |

---

## Container image

This chart builds and hosts no image. It deploys the official **contrib** distribution of the
OpenTelemetry Collector published on Docker Hub:
**[hub.docker.com/r/otel/opentelemetry-collector-contrib](https://hub.docker.com/r/otel/opentelemetry-collector-contrib)**.

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `otel/opentelemetry-collector-contrib` | Docker Hub repository |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |
| `command` | `["/otelcol-contrib"]` | Binary of that distribution |

The **contrib** distribution bundles the whole set of community receivers, processors and exporters
(Prometheus, Kafka, Loki, cloud vendors, …), which the core distribution does not carry. It is the
image this chart is written for, and `command` matches its binary.

> **Pin a tag.** `latest` is convenient for a first try but is not reproducible: two pods of the
> same release can end up on two different builds. Set `image.tag` to an explicit version for
> anything beyond a test.

```yaml
image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.157.0"
  pullPolicy: IfNotPresent
command:
  - "/otelcol-contrib"
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
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector

# Pinned version, own values, dedicated namespace
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability --create-namespace \
  --values my-values.yaml
```

`my-values.yaml` only holds what you override; everything else falls back to
[`values.yaml`](values.yaml).

Inspect before installing:

```bash
helm show values oci://ghcr.io/willbrid/charts/otelcollector    # all available values
helm template otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --values my-values.yaml                                       # rendered manifests
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --values my-values.yaml --dry-run --debug                     # server-side validation
```

## Upgrade

```bash
helm upgrade otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability \
  --values my-values.yaml
```

A configuration change alone restarts the pods: the Deployment carries a `checksum/config`
annotation computed from the rendered configuration.

## Uninstall

```bash
helm uninstall otelcollector --namespace observability
```

---

## Example scenarios

Complete values files, one per installation shape, in [`docs/`](docs/). Each page carries the values,
the install command and how to check the result.

| # | Scenario | What it covers |
|---|---|---|
| 1 | [Quick start](docs/01-quickstart.md) | OTLP in, `debug` out — proving senders reach the collector |
| 2 | [Configuration as a file](docs/02-config-from-file.md) | `--set-file config=…`, Helm templating inside the collector file |
| 3 | [Tempo, Prometheus and Loki](docs/03-export-to-backend.md) | One backend per signal, remote-write password kept in a Secret |
| 4 | [TLS on the receivers](docs/04-tls.md) | Certificate from a Secret through `volumes`/`volumeMounts`, optional mTLS |
| 5 | [OTLP from outside](docs/05-ingress-otlp.md) | Public OTLP/HTTP endpoint behind an Ingress, protected by a bearer token |
| 6 | [Production gateway](docs/06-gateway-sizing.md) | HPA, anti-affinity, self-metrics on 8888, `zpages`, queue sizing |

---

## Configuration

| Section | Description |
|---|---|
| `image` | Collector image and pull policy |
| `command`, `configMountPath` | Entrypoint and where the configuration file is read from |
| `config` | The collector configuration itself, inline or through `--set-file` |
| `service` | Service type and the list of exposed ports |
| `secret` | Sensitive env vars (exporter API keys, passwords) — stored in a Secret |
| `configmap` | Non-sensitive env vars (endpoints, resource attributes) — stored in a ConfigMap |
| `ingress`, `httpRoute` | Optional external exposure (Ingress or Gateway API) |
| `livenessProbe`, `readinessProbe` | Health checks against the `health_check` extension |
| `replicaCount`, `autoscaling` | Number of pods, fixed or driven by an HPA |
| `volumes`, `volumeMounts` | Extra volumes (TLS material, file exporter storage, …) |
| `resources`, `nodeSelector`, `tolerations`, `affinity` | Scheduling and limits |

### Injecting the collector configuration

The configuration is rendered into the `otel-collector-config.yaml` key of the ConfigMap
`<fullname>-config`, mounted at `configMountPath` (`/conf`), and passed to the binary as
`--config=<configMountPath>/otel-collector-config.yaml`.

Inline, in your values file:

```yaml
config: |
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317
        http:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4318

  processors:
    batch: {}

  exporters:
    debug:
      verbosity: basic

  extensions:
    health_check:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133

  service:
    extensions: [health_check]
    pipelines:
      traces:
        receivers: [otlp]
        processors: [batch]
        exporters: [debug]
```

Or from an existing file, without touching the values at all:

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --set-file config=./otel-collector-config.yaml
```

The content goes through `tpl`, so Helm expressions such as `{{ .Release.Namespace }}` are resolved,
while the collector `${env:VAR}` placeholders are left untouched.

### `OTEL_COLLECTOR_POD_IP`

The chart always injects this variable into the container, filled with the pod IP through the
downward API. Bind the receivers to it rather than to `0.0.0.0`, which the collector reports as an
insecure default, while keeping them reachable from the other pods of the cluster:

```yaml
endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317
```

It is managed by the chart and cannot be overridden from the values.

### Multiple ports

Each `service.ports` entry drives both the Service port and the matching container port. Declaring
a port is not enough — the matching receiver or extension must exist in the configuration.

```yaml
service:
  type: ClusterIP
  ports:
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: health
      port: 13133
      targetPort: 13133
      protocol: TCP
    - name: zipkin           # needs the zipkin receiver in `config`
      port: 9411
      targetPort: 9411
      protocol: TCP
```

Names are unique and limited to 15 characters (a Kubernetes constraint), and the first entry is the
default backend of the Ingress and the HTTPRoute — both of which can also target another entry by
name or number through their `port` value.

### Probes

Both probes hit the `health` port, which the `health_check` extension answers on. Keep that
extension enabled **and** listed under `service.extensions` in the configuration, otherwise nothing
answers and the pod never becomes ready:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: health
readinessProbe:
  httpGet:
    path: /
    port: health
```

### Environment variables

Two sections, injected with `envFrom` and referenced from the configuration as `${env:VAR}`. Each
resource is created only when its section is non-empty.

```yaml
secret:                      # base64-encoded, into a Secret
  OTLP_EXPORTER_API_KEY: "changeme"

configmap:                   # plain text, into a ConfigMap
  GOMEMLIMIT: "400MiB"
  OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=production"
```

> `secret` values sit in plain text in your values file and in the release. For real credentials,
> prefer an external secret manager and reference the Secret it produces.

### Extra volumes

The `config` volume and its read-only mount at `configMountPath` are always added by the chart.
Only extra volumes belong in `volumes`/`volumeMounts`, and they must not reuse the `config` name:

```yaml
volumes:
  - name: tls
    secret:
      secretName: collector-tls
volumeMounts:
  - name: tls
    mountPath: /etc/tls
    readOnly: true
```

---

## Reference

- All values, documented inline: [`values.yaml`](values.yaml)
- Working configurations covering each feature: [`ci/`](ci/) — one file per scenario, exercised by
  the CI on a real cluster
- Collector configuration reference: <https://opentelemetry.io/docs/collector/configuration/>
