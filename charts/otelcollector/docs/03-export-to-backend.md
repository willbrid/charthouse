# Exporting to Tempo, Prometheus and Loki

The three signals split across the three backends that usually receive them: traces to Tempo over
OTLP, metrics to Prometheus over remote write, logs to Loki over OTLP/HTTP. All three run in the
cluster here. The one credential involved — the remote-write password — travels through a Secret and
is read back as an environment variable, so the ConfigMap holding the pipelines stays free of it.

## Values

```yaml
# values-backend.yaml
replicaCount: 2

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.157.0"

command:
  - "/otelcol-contrib"

# base64 in the Secret <fullname>, pulled in with envFrom. Referenced from the
# configuration below as ${env:PROMETHEUS_RW_PASSWORD} — the collector resolves
# it at startup, so the password never appears in the ConfigMap.
secret:
  PROMETHEUS_RW_PASSWORD: "changeme"

configmap:
  # Go honours this as a soft memory ceiling, which keeps the garbage collector
  # working before the kernel OOM-kills the container.
  GOMEMLIMIT: "800MiB"
  OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=production"

service:
  type: ClusterIP
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
    - name: health
      port: 13133
      targetPort: 13133
      protocol: TCP

config: |
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317
        http:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4318

  processors:
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25
    batch:
      timeout: 5s
      send_batch_size: 8192
      send_batch_max_size: 10000

  exporters:
    # Traces — Tempo speaks OTLP natively on 4317.
    otlp/tempo:
      endpoint: tempo.observability.svc.cluster.local:4317
      tls:
        insecure: true
      retry_on_failure:
        enabled: true
        initial_interval: 5s
        max_elapsed_time: 300s
      sending_queue:
        enabled: true
        queue_size: 5000

    # Metrics — Prometheus accepts remote write only when started with
    # --web.enable-remote-write-receiver (or on Mimir/Thanos, which do by
    # default). Dots in OTLP attribute names become underscores on the way in.
    prometheusremotewrite/prometheus:
      endpoint: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
      auth:
        authenticator: basicauth/prometheus
      tls:
        insecure: true
      # Emits the target_info series carrying the resource attributes, which is
      # how you join a metric back to its pod, namespace and service.
      target_info:
        enabled: true
      retry_on_failure:
        enabled: true
      sending_queue:
        enabled: true
        queue_size: 5000

    # Logs — Loki 3.x exposes an OTLP endpoint under /otlp; the exporter appends
    # /v1/logs to it on its own.
    otlphttp/loki:
      endpoint: http://loki.observability.svc.cluster.local:3100/otlp
      compression: gzip
      headers:
        # Required as soon as Loki runs multi-tenant; harmless otherwise.
        X-Scope-OrgID: "production"
      retry_on_failure:
        enabled: true
      sending_queue:
        enabled: true
        queue_size: 5000

  extensions:
    health_check:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133
    basicauth/prometheus:
      client_auth:
        username: otel
        password: ${env:PROMETHEUS_RW_PASSWORD}

  service:
    extensions: [health_check, basicauth/prometheus]
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheusremotewrite/prometheus]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlphttp/loki]

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 1Gi
```

## Install

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability --create-namespace \
  --values values-backend.yaml
```

For a real password, keep it out of the values file entirely and pass it at install time:

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 --namespace observability --create-namespace \
  --values values-backend.yaml \
  --set secret.PROMETHEUS_RW_PASSWORD="$(vault kv get -field=password secret/prometheus-rw)"
```

Against a plain in-cluster Prometheus with no authentication, drop the `auth` block of the exporter
and `basicauth/prometheus` from both `extensions` blocks — and the `secret` section with them.

## Verify the data leaves

```bash
# the collector reports its own export failures here
kubectl -n observability logs deploy/otelcollector | grep -i "exporter\|permanent error"

# does the pod reach each backend at all?
kubectl -n observability exec deploy/otelcollector -- nc -zv tempo.observability.svc.cluster.local 4317
kubectl -n observability exec deploy/otelcollector -- nc -zv prometheus.observability.svc.cluster.local 9090
kubectl -n observability exec deploy/otelcollector -- nc -zv loki.observability.svc.cluster.local 3100

# then query the far end
# Tempo:      look the trace id up in Grafana
# Prometheus: curl -s 'http://prometheus:9090/api/v1/query?query=target_info'
# Loki:       curl -s -H 'X-Scope-OrgID: production' \
#               'http://loki:3100/loki/api/v1/labels'
```

## What to know

- **Three exporters, three failure modes.** They are independent: Loki being down does not stop
  traces reaching Tempo. Watch the collector's own logs per exporter name, not globally.
- **`sending_queue` plus `retry_on_failure` is what absorbs a backend outage.** The queue is
  in-memory, so a pod restart drops it. Sizing it above what `memory_limiter` allows just moves the
  failure.
- **An exporter defined but absent from a pipeline is dead configuration.** The collector starts
  fine and sends nothing — check `service.pipelines` first when a signal goes missing.
- **Remote write is not Prometheus scraping.** Prometheus must be started with
  `--web.enable-remote-write-receiver`; without it every push comes back `404` and the queue fills
  up. If you would rather have Prometheus scrape the collector, use the `prometheus` **exporter**
  instead and publish its port — see [Production gateway](06-gateway-sizing.md).
- **`${env:...}` in the config is resolved by the collector, not by Helm.** The variable must exist
  in the container, which is what the `secret` section arranges through `envFrom`. It is read once,
  at startup — changing the Secret takes effect on the restart the checksum annotation triggers.
