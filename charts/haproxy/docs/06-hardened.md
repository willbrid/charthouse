# A hardened deployment

Everything the chart can close, closed: the `restricted` Pod Security Standard, a NetworkPolicy
governing both directions, no API token, a disruption budget, and replicas that cannot all land on
the same node. A proxy is reachable by design and forwards wherever its configuration says — it is
worth bounding on both sides.

The chart defaults already pass `restricted`. This page is the rest.

## Values

```yaml
# values-hardened.yaml
kind: Deployment
replicaCount: 3

image:
  repository: haproxy
  # Pinned to a patch release, not a branch and certainly not `latest`: in a
  # hardened install you want to know exactly what is running.
  tag: "3.4.3"
  pullPolicy: IfNotPresent

# The chart defaults, restated so a change to them fails review rather than passing
# unnoticed. This is what `restricted` requires: non-root, no capability, no
# escalation, a seccomp profile, and a read-only root filesystem on top.
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 99
  runAsGroup: 99
  fsGroup: 99
  seccompProfile:
    type: RuntimeDefault

securityContext:
  capabilities:
    drop: [ALL]
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true

# HAProxy never calls the Kubernetes API. A mounted token would be a credential with
# no use and a real blast radius if the proxy is ever compromised.
serviceAccount:
  create: true
  automount: false

config: |
  global
      log stdout format raw local0 info
      maxconn 8192
      ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

  defaults
      log     global
      mode    http
      option  httplog
      option  dontlognull
      retries 2
      timeout connect 5s
      timeout client  30s
      timeout server  30s
      # A slow-loris client holding a half-sent request costs a connection slot
      # until this fires.
      timeout http-request 10s
      timeout queue 10s

  frontend health
      bind *:8404
      mode http
      http-request set-log-level silent
      monitor-uri /healthz
      http-request use-service prometheus-exporter if { path /metrics }
      # No stats page here: the HTML page and its password are one more thing to
      # protect. Metrics carry what monitoring needs.

  frontend http_in
      bind *:8080
      mode http

      # Rate limit per source address: 20 requests per 10 seconds, tracked in a
      # stick table that costs 1 MB for 100k sources.
      stick-table type ip size 100k expire 10s store http_req_rate(10s)
      http-request track-sc0 src
      http-request deny deny_status 429 if { sc_http_req_rate(0) gt 20 }

      # Do not let a client dictate what the backends believe about the client.
      http-request del-header X-Forwarded-For
      http-request del-header X-Forwarded-Proto
      http-request set-header X-Forwarded-For %[src]
      http-request set-header X-Forwarded-Proto http

      # Nothing about the proxy in the response.
      http-response del-header Server
      http-response set-header X-Content-Type-Options nosniff

      default_backend app

  backend app
      mode http
      balance roundrobin
      option httpchk GET /healthz
      http-check expect status 200
      server app1 app.default.svc.cluster.local:8080 check inter 2s fall 3 rise 2

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

# Both directions governed. Everything not listed is denied — including, without the
# DNS rule, the resolution of the backend below.
networkPolicy:
  enabled: true
  allowDNS: true
  dns:
    namespace: kube-system
    podSelector:
      k8s-app: kube-dns
    ports:
      - protocol: UDP
        port: 53
      - protocol: TCP
        port: 53
  ingress:
    # Clients: the traffic port, from the namespaces allowed to use this proxy.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: frontend
      ports:
        - protocol: TCP
          port: 8080
    # Monitoring: the health port, from the monitoring namespace only.
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - protocol: TCP
          port: 8404
  egress:
    # The one backend this proxy exists to reach. Nothing else — not the API server,
    # not the internet, not the other namespaces.
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: default
          podSelector:
            matchLabels:
              app.kubernetes.io/name: my-app
      ports:
        - protocol: TCP
          port: 8080

# Three replicas that cannot share a node, and a drain that moves one at a time.
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: haproxy

podDisruptionBudget:
  enabled: true
  minAvailable: 2

deployment:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0

lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
terminationGracePeriodSeconds: 30

# A limit a proxy hits is throttling on the request path. Request generously, cap
# memory rather than CPU.
resources:
  requests:
    cpu: 500m
    memory: 256Mi
  limits:
    memory: 512Mi
```

## Install

Into a namespace that enforces the standard, so a future change that breaks it is rejected by the API
server and not only by review:

```bash
kubectl create namespace edge
kubectl label namespace edge \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 --namespace edge --values values-hardened.yaml
```

## Verify

```bash
# Admitted by the restricted standard — no warning printed at install time
kubectl get pods -n edge

# Running as 99, nothing mounted from the service account
kubectl exec -n edge deploy/haproxy -c haproxy -- id
# uid=99(haproxy) gid=99(haproxy) groups=99(haproxy)
kubectl exec -n edge deploy/haproxy -c haproxy -- ls /var/run/secrets/kubernetes.io 2>&1
# No such file or directory

# The root filesystem really is read-only
kubectl exec -n edge deploy/haproxy -c haproxy -- touch /tmp/x 2>&1
# touch: cannot touch '/tmp/x': Read-only file system

# The policy is applied, and — on a CNI that enforces it — it bites
kubectl describe networkpolicy -n edge haproxy
kubectl exec -n edge deploy/haproxy -c haproxy -- \
  bash -c 'timeout 4 bash -c "echo > /dev/tcp/10.96.0.1/443"' \
  && echo "REACHED — policy not enforced" || echo "BLOCKED"
```

That last check matters: a NetworkPolicy is enforced by the CNI, not by Kubernetes. Under a plugin
that ignores them the object exists and restricts nothing, silently, which is the worst of both
worlds. Prove it on your own cluster before counting on it.

## What to know

- **The rate limit is per pod, not per release.** Three replicas with `gt 20` allow up to 60 requests
  per 10 s from one source, depending on how the Service spreads them. A `peers` section can
  synchronise the stick tables across the replicas if the exact number matters.
- **`readOnlyRootFilesystem: true` is fine until it is not.** A `stats socket` on a UNIX path, a
  `server-state-file`, or the ACME support of recent branches all need somewhere to write. Add an
  `emptyDir` in `volumes` for that path — do not flip the flag.
- **The egress rule is the one people forget.** Governing egress and then not listing a backend gives
  a proxy that answers 503 for reasons no log explains. Every backend the configuration names needs a
  rule, and so does DNS.
- **`minAvailable: 2` with `replicaCount: 3` blocks a drain that would take two.** With
  `whenUnsatisfiable: DoNotSchedule`, a cluster with fewer than three nodes leaves a pod `Pending` —
  intended, but check it against your node count.
- **Deleting the health port to hide it also deletes the probes' target.** Restrict it with the
  policy above instead.
