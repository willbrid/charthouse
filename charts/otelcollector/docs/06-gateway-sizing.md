# Production gateway — scaling, self-observability and debugging ports

The shape to run a shared collector in front of a whole cluster: several replicas spread across
nodes, an HPA to follow the load, the collector's own metrics exposed for Prometheus to scrape, and
`zpages` published for when a pipeline misbehaves.

## Values

```yaml
# values-gateway.yaml
# Ignored while autoscaling is enabled — kept as the value to fall back to.
replicaCount: 3

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.157.0"

command:
  - "/otelcol-contrib"

configmap:
  # Soft ceiling below the container limit, so Go collects garbage before the
  # kernel OOM-kills the process. Roughly 80% of resources.limits.memory.
  GOMEMLIMIT: "1600MiB"
  # The collector is CPU-bound on serialization; leaving GOMAXPROCS to the node
  # core count while the cgroup allows 2 CPUs wastes time in the scheduler.
  GOMAXPROCS: "2"

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
    # The collector's own metrics — how full the queues are, what got dropped.
    - name: metrics
      port: 8888
      targetPort: 8888
      protocol: TCP
    # Live pipeline inspection. Internal only, see the note below.
    - name: zpages
      port: 55679
      targetPort: 55679
      protocol: TCP

# Scraped by a Prometheus running in the cluster. Prefer a ServiceMonitor if you
# run the Prometheus operator — this works without it.
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8888"
  prometheus.io/path: "/metrics"

config: |
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317
          # A single sender must not be able to fill the whole heap.
          max_recv_msg_size_mib: 8
        http:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4318

  processors:
    memory_limiter:
      check_interval: 1s
      limit_percentage: 75
      spike_limit_percentage: 15
    batch:
      timeout: 5s
      send_batch_size: 8192
      send_batch_max_size: 10000

  exporters:
    otlp/tempo:
      endpoint: tempo.observability.svc.cluster.local:4317
      tls:
        insecure: true
      sending_queue:
        enabled: true
        num_consumers: 10
        queue_size: 10000
      retry_on_failure:
        enabled: true
        max_elapsed_time: 300s

  extensions:
    health_check:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133
    zpages:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:55679

  service:
    extensions: [health_check, zpages]
    telemetry:
      logs:
        level: warn
      metrics:
        readers:
          - pull:
              exporter:
                prometheus:
                  host: ${env:OTEL_COLLECTOR_POD_IP}
                  port: 8888
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 12
  targetCPUUtilizationPercentage: 70

# Requests and limits equal on memory: the collector's whole back-pressure
# design assumes a known ceiling, and memory_limiter is calibrated against it.
resources:
  requests:
    cpu: "1"
    memory: 2Gi
  limits:
    cpu: "2"
    memory: 2Gi

# One pod per node as far as possible: losing a node should cost one replica.
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: otelcollector

livenessProbe:
  httpGet:
    path: /
    port: health
  initialDelaySeconds: 15
  periodSeconds: 10
  failureThreshold: 5
readinessProbe:
  httpGet:
    path: /
    port: health
  initialDelaySeconds: 5
  periodSeconds: 5
```

## Install

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability --create-namespace \
  --values values-gateway.yaml
```

## The four metrics worth alerting on

```bash
kubectl -n observability port-forward svc/otelcollector 8888:8888 &
curl -s http://localhost:8888/metrics | grep -E \
  'otelcol_processor_refused|otelcol_exporter_send_failed|otelcol_exporter_queue_size|otelcol_receiver_refused'
```

| Metric | What a non-zero value means |
|---|---|
| `otelcol_receiver_refused_spans` | Senders outran the collector — scale out, or the sender retries |
| `otelcol_processor_refused_spans` | `memory_limiter` shed load: the pod is at its ceiling |
| `otelcol_exporter_send_failed_spans` | The backend rejected or was unreachable — data lost after retries |
| `otelcol_exporter_queue_size` vs `_queue_capacity` | A queue near capacity is an outage about to become data loss |

## What to know

- **`autoscaling.enabled: true` removes `replicas` from the Deployment**, handing the count to the
  HPA; `replicaCount` is then only the value the manifest falls back to.
- **CPU is the right scaling signal, memory is not.** The collector holds its queues in memory by
  design, so memory sits near the limit at steady state and a memory-based HPA scales out
  permanently.
- **Do not publish `zpages` outside the cluster.** It exposes live span content — sampled payloads
  from every application sending to this collector. Keep the service `ClusterIP` and reach it by
  port-forward: `kubectl -n observability port-forward svc/otelcollector 55679:55679`, then
  `http://localhost:55679/debug/tracez`.
- **An in-memory `sending_queue` dies with the pod.** With `maxReplicas: 12` and an HPA scaling in,
  each removed pod drops whatever it had queued. A file-backed queue
  (`file_storage` extension plus `sending_queue.storage`) is the fix, and needs a volume.
- **`memory_limiter` must come first in every pipeline.** Placed after `batch`, it sheds load only
  once the batches are already built — which is the memory you were trying not to spend.
