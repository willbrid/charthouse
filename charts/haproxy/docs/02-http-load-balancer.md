# An in-cluster HTTP load balancer

A single entry point in front of several services: routing by host and by path, active health checks
that take a broken backend out before a client notices, and retries on the ones that are safe to
retry. This is what HAProxy is for, and it is all configuration — the chart's job here is to deliver
the file, check it and keep the pods healthy.

## Values

```yaml
# values-lb.yaml
kind: Deployment
replicaCount: 3

image:
  repository: haproxy
  tag: "3.4"
  pullPolicy: IfNotPresent

# Backend addresses live in a ConfigMap rather than in the configuration file, so the
# same file serves staging and production. HAProxy expands ${VAR} when it reads it —
# and the config-check init container gets the same variables, so what is validated
# is what runs.
configmap:
  API_BACKEND: "api.default.svc.cluster.local"
  WEB_BACKEND: "web.default.svc.cluster.local"

config: |
  global
      log stdout format raw local0 info
      maxconn 8192

  defaults
      log     global
      mode    http
      option  httplog
      option  dontlognull
      # Do not count a connection refused as a client-visible error: try the next
      # server instead. Only safe for idempotent requests, hence `option redispatch`
      # paired with a retry count that stays small.
      retries 2
      option  redispatch
      timeout connect 5s
      timeout client  50s
      timeout server  50s
      timeout http-request 10s
      # An idle keep-alive connection to a backend costs nothing and saves a
      # handshake on the next request.
      timeout http-keep-alive 60s

  frontend health
      bind *:8404
      mode http
      http-request set-log-level silent
      monitor-uri /healthz
      http-request use-service prometheus-exporter if { path /metrics }
      stats enable
      stats uri /stats
      stats refresh 10s

  frontend http_in
      bind *:8080
      mode http

      # Who the client was, for the backends behind the proxy.
      http-request set-header X-Forwarded-Proto http
      http-request set-header X-Forwarded-For %[src]

      # Routing. First match wins, so the specific rules come before the general one.
      acl host_api  hdr(host) -i api.example.com
      acl path_api  path_beg /api/
      use_backend api_backend if host_api
      use_backend api_backend if path_api
      default_backend web_backend

  backend api_backend
      mode http
      balance roundrobin
      # An active check: HAProxy asks the server itself rather than trusting that a
      # ready pod is a working one. `check inter 2s fall 3 rise 2` takes a server out
      # after 3 consecutive failures and puts it back after 2 successes.
      option httpchk GET /healthz
      http-check expect status 200
      server api1 ${API_BACKEND}:8080 check inter 2s fall 3 rise 2

  backend web_backend
      mode http
      balance roundrobin
      option httpchk GET /
      server web1 ${WEB_BACKEND}:80 check inter 2s fall 3 rise 2

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

# A proxy on the critical path: spread the replicas, keep serving during rollouts,
# and let a drain move one pod at a time.
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: haproxy

deployment:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

# The gap between "removed from the endpoints" and "sent SIGTERM" is where in-flight
# requests are lost on every rollout.
lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
terminationGracePeriodSeconds: 30

resources:
  requests:
    cpu: 200m
    memory: 128Mi
  limits:
    memory: 512Mi
```

## Install

```bash
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 \
  --namespace edge --create-namespace \
  --values values-lb.yaml
```

## Verify the routing

From any pod in the cluster:

```bash
kubectl run probe -n edge --rm -it --image=busybox --restart=Never -- sh

wget -q -S -O - --header="Host: api.example.com" http://haproxy/     # → api_backend
wget -q -S -O - http://haproxy/api/v1/things                         # → api_backend
wget -q -S -O - http://haproxy/                                      # → web_backend
```

And check the decision HAProxy made, from the stats page rather than by guessing:

```bash
kubectl port-forward -n edge svc/haproxy 8404:8404
open http://127.0.0.1:8404/stats
```

The per-server rows show the health-check state (`UP`/`DOWN`), the number of sessions each server
took, and the last check result — which is where a `L7STS/404` tells you `option httpchk` is asking
for a path the backend does not serve.

```bash
# The same, scriptable
kubectl exec -n edge deploy/haproxy -- \
  sh -c 'wget -qO- "http://127.0.0.1:8404/stats;csv"' | cut -d, -f1,2,18,37
```

## Following pods instead of the Service VIP

`server api1 api.default.svc.cluster.local:8080` resolves the Service ClusterIP once, at startup, and
lets kube-proxy pick the pod. That is fine, and it is one hop more than necessary. To have HAProxy
balance across the pods itself — and see each of them in the stats page — point it at a **headless**
service and let it re-resolve:

```
resolvers kube
    parse-resolv-conf
    hold valid 10s

backend api_backend
    balance roundrobin
    option httpchk GET /healthz
    # 10 slots filled from the DNS records, refreshed by the resolver above
    server-template api 10 api-headless.default.svc.cluster.local:8080 check resolvers kube init-addr none
```

`init-addr none` is what keeps HAProxy from refusing to start when the backend has no pod yet — a
proxy that will not start because its backend is down is a proxy that cannot come back with it.

## What to know

- **`option httpchk` asks the server, not Kubernetes.** A pod that is `Ready` but broken is taken out
  by HAProxy and not by the endpoint controller. That is the point of putting a proxy there; make
  sure the path you check means something.
- **`retries` and `option redispatch` only apply to what is safe to retry.** HAProxy retries on
  connection failures, not on a 500 answered by the application. Do not raise `retries` to paper over
  a failing backend.
- **The routing rules are ordered.** `use_backend` matches top to bottom and the first hit wins;
  `default_backend` is the fallback. A rule that never fires usually sits behind a broader one.
- **`X-Forwarded-For` is set, not appended.** If a proxy upstream of this one already sets it, use
  `http-request add-header` or `option forwardfor` instead, and do not trust the value from the
  outside world.
- **Check the config before shipping it.** `helm template ... | ...` renders it; the `config-check`
  init container is what actually blocks a bad one, and `helm upgrade` keeps the old pods serving
  while the new one fails to start.
