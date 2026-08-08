# Accepting OTLP from outside the cluster

Applications that do not run in this cluster — a mobile backend, a VM fleet, a CI runner — sending
OTLP/HTTP to a public hostname. The Ingress terminates TLS and forwards to the `otlp-http` port;
gRPC is left on the internal service, since exposing it through an Ingress is controller-specific
and rarely worth it.

Requires an Ingress controller (nginx here) and cert-manager for the certificate.

## Values

```yaml
# values-ingress.yaml
replicaCount: 2

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.157.0"

command:
  - "/otelcol-contrib"

secret:
  # Shared bearer token the outside senders present. Anything reachable from the
  # internet needs one — an open OTLP endpoint is an open write to your bill.
  OTLP_INGEST_TOKEN: "changeme"

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

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # OTLP payloads are batched and gzipped; the default 1m body limit rejects
    # the larger ones with a 413 the sender reports as a generic export failure.
    nginx.ingress.kubernetes.io/proxy-body-size: "16m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "60"
  # Backend port for the paths that do not name their own. Accepts a name from
  # service.ports or a number; empty would take the first entry.
  port: otlp-http
  hosts:
    - host: otlp.example.com
      paths:
        - path: /v1
          pathType: Prefix
  tls:
    - secretName: otelcollector-tls
      hosts:
        - otlp.example.com

config: |
  receivers:
    otlp:
      protocols:
        http:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4318
          # Every request must carry the token; the extension below checks it.
          auth:
            authenticator: bearertokenauth/ingest
          # Browsers preflight cross-origin exports. Drop this block if only
          # servers send to this endpoint.
          cors:
            allowed_origins:
              - https://app.example.com
            max_age: 7200
        grpc:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317

  processors:
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25
    batch:
      timeout: 5s
      send_batch_size: 8192

  exporters:
    otlp/tempo:
      endpoint: tempo.observability.svc.cluster.local:4317
      tls:
        insecure: true
      sending_queue:
        enabled: true
        queue_size: 5000

  extensions:
    health_check:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133
    bearertokenauth/ingest:
      token: ${env:OTLP_INGEST_TOKEN}

  service:
    extensions: [health_check, bearertokenauth/ingest]
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]

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
  --values values-ingress.yaml
```

## Verify from outside

```bash
kubectl -n observability get ingress otelcollector

# without the token: 401
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://otlp.example.com/v1/traces \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[]}'

# with it: 200
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://otlp.example.com/v1/traces \
  -H 'Authorization: Bearer changeme' \
  -H 'Content-Type: application/json' -d '{"resourceSpans":[]}'
```

A sender is then configured with:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.example.com
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer%20changeme
```

## What to know

- **The Ingress path must cover what the SDK dials.** OTLP/HTTP posts to `/v1/traces`, `/v1/metrics`
  and `/v1/logs`; the `/v1` prefix above catches all three. A `path: /` works too but hands every
  other request on that hostname to the collector.
- **gRPC through an Ingress is a different exercise.** nginx needs
  `nginx.ingress.kubernetes.io/backend-protocol: "GRPC"` on a *separate* Ingress, since the
  annotation applies to the whole object. Most setups keep gRPC internal and let outside senders use
  HTTP, which is what this scenario does.
- **Authentication is not optional here.** Without `bearertokenauth`, anyone who resolves the
  hostname can write into your traces backend. Rotate the token by updating the Secret and rolling
  the deployment.
- **The token check happens in the collector, after the Ingress.** Rejected requests still cost you
  a TLS handshake and a proxy hop — put rate limiting on the controller if the endpoint is public.
- For mutual TLS instead of a bearer token, terminate at the collector rather than the Ingress:
  see [TLS on the OTLP receivers](04-tls.md) and use a `LoadBalancer` service.
