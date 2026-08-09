# Prometheus metrics and the stats page

The official image is built with `USE_PROMEX=1`, so HAProxy exports Prometheus metrics itself — no
sidecar, no `haproxy_exporter`, no stats socket to scrape. The chart's default configuration turns it
on, on the port named `health`. This page is about what comes out of it, how to scrape it, and what
is worth alerting on.

## Values

```yaml
# values-metrics.yaml
kind: Deployment
replicaCount: 2

image:
  repository: haproxy
  tag: "3.4"
  pullPolicy: IfNotPresent

# Password for the stats page, expanded by HAProxy as ${STATS_PASSWORD} when it reads
# the configuration. Put a real one in a Secret you manage, or use --set.
secret:
  STATS_PASSWORD: "changeme"

config: |
  global
      log stdout format raw local0 info
      maxconn 4096

  defaults
      log     global
      mode    http
      option  httplog
      option  dontlognull
      retries 2
      timeout connect 5s
      timeout client  50s
      timeout server  50s

  frontend health
      bind *:8404
      mode http
      # Probes and scrapes are frequent and say nothing; keeping them out of the log
      # is the difference between a readable log and a wall of 200s.
      http-request set-log-level silent

      # 200 while the process runs. This is what the probes call.
      monitor-uri /healthz

      # The exporter. `scope *` includes every proxy; drop the scope to export only
      # the frontends and backends that carry the `stats` scope.
      http-request use-service prometheus-exporter if { path /metrics }

      # The HTML page, behind a password. Everything it shows — backend names,
      # server addresses, counters — is information about the inside of the cluster.
      stats enable
      stats uri /stats
      stats refresh 10s
      stats realm HAProxy\ Statistics
      stats auth admin:${STATS_PASSWORD}
      # `stats admin` would add buttons to disable servers from the browser. Leave it
      # off unless you mean it: it is a write endpoint behind a shared password.

  frontend http_in
      bind *:8080
      mode http
      default_backend app

  backend app
      mode http
      balance roundrobin
      option httpchk GET /healthz
      server app1 app.default.svc.cluster.local:8080 check

service:
  enabled: true
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
    - name: health
      port: 8404
      targetPort: 8404
      protocol: TCP

# For a Prometheus doing pod discovery. With the Prometheus Operator, write a
# ServiceMonitor instead — see below.
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8404"
  prometheus.io/path: "/metrics"

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 512Mi
```

## Install

```bash
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 \
  --namespace edge --create-namespace \
  --values values-metrics.yaml
```

## What comes out

```bash
kubectl port-forward -n edge svc/haproxy 8404:8404
curl -s http://127.0.0.1:8404/metrics | grep -E '^haproxy_(backend|frontend|server)_' | head
```

The families worth knowing, all labelled by `proxy` (the frontend or backend name) and, for servers,
by `server`:

| Metric | Reads as |
|---|---|
| `haproxy_frontend_http_responses_total{code="5xx"}` | Errors the clients saw |
| `haproxy_frontend_current_sessions` | Concurrent clients, per frontend |
| `haproxy_frontend_limit_sessions` | The `maxconn` ceiling those sessions run into |
| `haproxy_backend_up` | 1 while the backend has at least one usable server |
| `haproxy_server_up` | 1 per server, 0 when its health check fails |
| `haproxy_backend_response_time_average_seconds` | Backend latency as HAProxy measures it |
| `haproxy_backend_connection_errors_total` | Connections HAProxy could not open |
| `haproxy_backend_retries_total` | Requests it had to send again |
| `haproxy_process_current_connections` | Load on the process itself |

Four alerts that pay for themselves:

```yaml
# No usable server behind a backend — the proxy is answering 503
- alert: HAProxyBackendDown
  expr: haproxy_backend_up == 0
  for: 1m

# Servers flapping in and out of a backend
- alert: HAProxyServerFlapping
  expr: changes(haproxy_server_up[10m]) > 4

# Client-visible errors
- alert: HAProxyHigh5xx
  expr: |
    sum by (proxy) (rate(haproxy_frontend_http_responses_total{code="5xx"}[5m]))
      / sum by (proxy) (rate(haproxy_frontend_http_responses_total[5m])) > 0.05
  for: 5m

# Approaching the connection ceiling, which HAProxy answers by queueing
- alert: HAProxyNearMaxconn
  expr: haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions > 0.8
  for: 5m
```

## Scraping with the Prometheus Operator

The chart creates no `ServiceMonitor` — it would need the CRD to be installed, and a chart that fails
to render on a cluster without Prometheus is a bad trade. Write it next to your values:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: haproxy
  namespace: edge
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: haproxy
      app.kubernetes.io/instance: haproxy
  endpoints:
    - port: health          # the service port name, not the number
      path: /metrics
      interval: 30s
```

## The stats page

```bash
kubectl port-forward -n edge svc/haproxy 8404:8404
open http://127.0.0.1:8404/stats          # admin / changeme
```

It answers the questions metrics do not: which server took the last request, what the last health
check returned (`L7STS/404` is a check hitting a path that does not exist), how long a server has
been down, how many sessions are queued. The same content, scriptable:

```bash
kubectl exec -n edge deploy/haproxy -- \
  sh -c 'wget -qO- "http://127.0.0.1:8404/stats;csv"' | cut -d, -f1,2,18,37,38
# pxname,svname,status,check_status,check_code
```

## What to know

- **This port is the inside of your cluster.** Backend names, server addresses, traffic volumes,
  and — with `stats admin` — the ability to disable a server. Restrict it: a
  [NetworkPolicy](../README.md#networkpolicy) limiting ingress on 8404 to the monitoring namespace,
  and `stats auth` on top.
- **`monitor-uri` and the probes are one thing.** Remove `monitor-uri /healthz` from the
  configuration and every pod goes unready, because that is what `livenessProbe`/`readinessProbe`
  call. Change the path in both places or in neither.
- **Metrics are per pod, not per release.** Each replica exports its own view; sum across them in
  PromQL, and expect the numbers to differ — the Service spreads connections unevenly by design.
- **The exporter is a service running inside HAProxy.** It costs a little CPU per scrape on a proxy
  with many servers; a 30 s interval is plenty.
