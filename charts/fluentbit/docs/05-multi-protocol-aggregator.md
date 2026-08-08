# Multi-protocol aggregator — forward, HTTP, TCP and syslog at once

One Fluent Bit accepting logs on four protocols, routing each source to its own tag, and exposing
the HTTP input through an Ingress so senders outside the cluster can post to it. This is the shape
for a central collector fed by things you do not control: appliances, VMs, third-party webhooks.

## Values

```yaml
# values-aggregator.yaml
kind: Deployment
replicaCount: 3

image:
  repository: fluent/fluent-bit
  tag: "5.0.9"

command:
  - "/fluent-bit/bin/fluent-bit"

configMountPath: /fluent-bit/etc
configFileName: fluent-bit.conf

secret:
  LOKI_BEARER_TOKEN: "changeme"

configmap:
  LOKI_HOST: "loki.logging.svc.cluster.local"

# Each entry publishes a service port and the matching container port. Names are
# capped at 15 characters by Kubernetes, and the chart rejects duplicates.
service:
  type: ClusterIP
  ports:
    - name: health
      port: 2020
      targetPort: 2020
      protocol: TCP
    - name: forward
      port: 24224
      targetPort: 24224
      protocol: TCP
    - name: http-in
      port: 9880
      targetPort: 9880
      protocol: TCP
    - name: tcp-json
      port: 5170
      targetPort: 5170
      protocol: TCP
    # Syslog over UDP. A UDP port in a Service works, but it is unrelated to the
    # TCP ports above — do not expect the Ingress to reach it.
    - name: syslog
      port: 5140
      targetPort: 5140
      protocol: UDP

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
  # Backend port for the paths that do not name their own. Without this the
  # first service.ports entry — health — would receive the traffic.
  port: http-in
  hosts:
    - host: logs.example.com
      paths:
        - path: /ingest
          pathType: Prefix
  tls:
    - secretName: fluentbit-tls
      hosts:
        - logs.example.com

config: |
  [SERVICE]
      daemon        Off
      flush         1
      log_level     info
      http_server   On
      http_listen   0.0.0.0
      http_port     2020
      health_check  On

  # Fluent Bit and Fluentd agents.
  [INPUT]
      name          forward
      listen        0.0.0.0
      port          24224
      tag           fwd
      mem_buf_limit 20MB

  # JSON over HTTP POST, which is what the Ingress above exposes. The tag is
  # taken from the URI path: POST /ingest/app.web tags records app.web.
  [INPUT]
      name          http
      listen        0.0.0.0
      port          9880
      tag           http
      mem_buf_limit 20MB

  # Raw JSON lines over a socket, one record per line.
  [INPUT]
      name          tcp
      listen        0.0.0.0
      port          5170
      tag           tcp
      format        json
      mem_buf_limit 20MB

  # Network appliances and anything else that only speaks RFC5424.
  [INPUT]
      name          syslog
      listen        0.0.0.0
      port          5140
      mode          udp
      tag           syslog
      parser        syslog-rfc5424

  # One label per source, so a query can select where a record came from
  # without a label per sender.
  [FILTER]
      name          record_modifier
      match         *
      record        collector fluentbit

  [OUTPUT]
      name                   loki
      match                  *
      host                   ${LOKI_HOST}
      port                   3100
      bearer_token           ${LOKI_BEARER_TOKEN}
      labels                 job=aggregator, source=$TAG
      line_format            json
      retry_limit            5

# Autoscaling fits a network aggregator: no per-pod state, and load follows the
# senders. Keep minReplicas above 1 so a rollout never leaves zero listeners.
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 75

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: fluentbit

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 512Mi
```

## Install

```bash
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging --create-namespace \
  --values values-aggregator.yaml
```

## Verify each protocol

```bash
kubectl -n logging get svc fluentbit          # five ports published

# HTTP, from outside
curl -s -X POST https://logs.example.com/ingest/app.web \
  -H 'Content-Type: application/json' \
  -d '{"level":"info","msg":"hello from outside"}'

# TCP and syslog, from inside
kubectl -n logging run probe --rm -it --restart=Never --image nicolaka/netshoot -- sh -c '
  echo "{\"level\":\"info\",\"msg\":\"over tcp\"}" | nc -w1 fluentbit 5170
  echo "<134>1 2026-01-01T00:00:00Z host app - - - over syslog" | nc -u -w1 fluentbit 5140
'

# what arrived, per input
kubectl -n logging port-forward svc/fluentbit 2020:2020 &
curl -s localhost:2020/api/v1/metrics | jq '.input'
```

## What to know

- **`ingress.port` matters here.** With several service ports, the Ingress backend defaults to the
  *first* entry — `health` in this file. Naming `http-in` explicitly is what sends the traffic to
  the right listener, and getting it wrong looks like a working Ingress returning nothing useful.
- **UDP does not go through an Ingress.** A syslog sender outside the cluster needs a
  `LoadBalancer` service, or a NodePort, and the Service must then carry the UDP port — an Ingress
  controller only proxies HTTP.
- **The HTTP input takes its tag from the URI.** `POST /ingest/app.web` under the `/ingest` prefix
  yields the tag `app.web`, which is how one endpoint serves many sources. Anything posted to the
  bare path keeps the input's own `tag`.
- **An open ingest endpoint is an open write.** The `http` input has no authentication of its own —
  put the check on the Ingress controller (`nginx.ingress.kubernetes.io/auth-*` annotations) or in
  front of it.
- **No filesystem buffer here**, so a pod restart drops what it held. If losing records during a
  backend outage is not acceptable, combine this with
  [Filesystem buffer](04-filesystem-buffer.md) — which means moving to `kind: StatefulSet` and
  turning autoscaling off.
