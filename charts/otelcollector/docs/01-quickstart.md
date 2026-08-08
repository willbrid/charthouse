# Quick start — an OTLP endpoint that prints what it receives

One collector, OTLP over gRPC and HTTP in, `debug` exporter out. Nothing is stored and nothing
leaves the cluster: this is the shape to install first, to prove your applications can reach the
collector before deciding where the data goes.

## Values

```yaml
# values-quickstart.yaml
replicaCount: 1

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.157.0"        # pin it: the collector changes configuration keys between releases
  pullPolicy: IfNotPresent

# Must match the distribution above: /otelcol-contrib for contrib,
# /otelcol for the core image (otel/opentelemetry-collector).
command:
  - "/otelcol-contrib"

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
    # Sheds load instead of being OOM-killed when senders outrun the exporters.
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25
    batch: {}

  exporters:
    debug:
      verbosity: normal

  extensions:
    health_check:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133

  service:
    extensions: [health_check]
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [debug]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [debug]
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [debug]

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi
```

## Install

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability --create-namespace \
  --values values-quickstart.yaml
```

## Send it a span and watch it arrive

```bash
kubectl -n observability port-forward svc/otelcollector 4318:4318 &

curl -s -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"probe"}}]},
       "scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c",
       "spanId":"eee19b7ec3c1b174","name":"hello","kind":1,
       "startTimeUnixNano":"1700000000000000000","endTimeUnixNano":"1700000000100000000"}]}]}]}'

kubectl -n observability logs deploy/otelcollector --tail=30    # the span is printed here
```

From inside the cluster, applications point at
`http://otelcollector.observability.svc.cluster.local:4318` (or `:4317` for gRPC).

## What to know

- **`${env:OTEL_COLLECTOR_POD_IP}` is injected by the chart** and cannot be set from the values.
  Bind receivers to it rather than `0.0.0.0`, which the collector flags as an insecure default while
  still being reachable from other pods.
- **A port in `service.ports` and a receiver in `config` are two halves of the same thing.** Adding a
  port without its receiver publishes a port nothing listens on; adding a receiver without its port
  makes it unreachable through the service.
- **`debug` is for proving connectivity, not for running.** Its output is unbounded and lands in the
  pod logs. Point the pipelines at a real backend next:
  [Exporting to a backend](03-export-to-backend.md).
- The `health_check` extension backs both probes and `helm test`. Remove it and the pod never becomes
  ready with the chart's default probes.
