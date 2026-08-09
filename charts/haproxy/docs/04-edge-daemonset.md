# An edge proxy on every node

One HAProxy per node, bound to the node's own network, taking traffic on ports 80 and 443 with no
Service and no cloud load balancer in front of it. This is how you put a proxy at the edge of a
bare-metal cluster: point DNS at the node addresses (or at a virtual IP floating between them) and
every node is an entry point.

It is also the configuration with the most ways to go wrong, so each of them is spelled out below.

## Values

```yaml
# values-edge.yaml
# One pod per node. replicaCount does not apply to this kind — the chart ignores it.
kind: DaemonSet

daemonSet:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      # One node at a time: the others keep taking traffic.
      maxUnavailable: 1

image:
  repository: haproxy
  tag: "3.4"
  pullPolicy: IfNotPresent

# The pod shares the network namespace of its node: the binds below are node ports.
# dnsPolicy is left empty so the chart derives ClusterFirstWithHostNet — without it
# the pod would use the node's resolver and stop resolving *.svc.cluster.local,
# which is where the backends are.
hostNetwork:
  enabled: true
  dnsPolicy: ""

# Binding 80 and 443 as uid 99 needs this one capability back. Everything else stays
# dropped, and the root filesystem stays read-only.
securityContext:
  capabilities:
    drop: [ALL]
    add: [NET_BIND_SERVICE]
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 99
  runAsGroup: 99
  seccompProfile:
    type: RuntimeDefault

volumes:
  - name: certs
    secret:
      secretName: haproxy-tls
      optional: false
volumeMounts:
  - name: certs
    mountPath: /etc/haproxy/certs
    readOnly: true

config: |
  global
      log stdout format raw local0 info
      maxconn 20000
      ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets

  defaults
      log     global
      mode    http
      option  httplog
      option  dontlognull
      retries 2
      option  redispatch
      timeout connect 5s
      timeout client  50s
      timeout server  50s
      timeout http-request 10s

  frontend health
      bind *:8404
      mode http
      http-request set-log-level silent
      monitor-uri /healthz
      http-request use-service prometheus-exporter if { path /metrics }

  frontend http_in
      bind *:80
      mode http
      http-request redirect scheme https code 301

  frontend https_in
      bind *:443 ssl crt /etc/haproxy/certs/
      mode http
      http-request set-header X-Forwarded-Proto https
      http-request set-header X-Forwarded-For %[src]
      default_backend app

  backend app
      mode http
      balance roundrobin
      option httpchk GET /healthz
      server app1 app.default.svc.cluster.local:8080 check

# No Service: the proxy is reached at the node address. The ports are still declared
# here — that is what gives the probes a name to target and the chart the numbers to
# mirror into hostPort, so a conflict shows up at scheduling time.
service:
  enabled: false
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
    - name: https
      port: 443
      targetPort: 443
      protocol: TCP
    - name: health
      port: 8404
      targetPort: 8404
      protocol: TCP

# An edge proxy is only an edge on the nodes it reaches. Control-plane nodes are
# tainted by default; include them only if they are meant to take public traffic.
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule

# Or, the other way round: keep it on the nodes labelled for it.
# nodeSelector:
#   node-role.kubernetes.io/edge: "true"

priorityClassName: system-cluster-critical

lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]
terminationGracePeriodSeconds: 30

resources:
  requests:
    cpu: 500m
    memory: 256Mi
  limits:
    memory: 1Gi
```

## Install

```bash
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 \
  --namespace edge --create-namespace \
  --values values-edge.yaml
```

## Verify

```bash
kubectl get pods -n edge -o wide          # one per node
kubectl get ds -n edge haproxy

# The DNS policy the chart derived
kubectl get ds -n edge haproxy -o jsonpath='{.spec.template.spec.dnsPolicy}{"\n"}'
# ClusterFirstWithHostNet

# The ports mirrored into hostPort
kubectl get ds -n edge haproxy -o jsonpath='{.spec.template.spec.containers[0].ports[*].hostPort}{"\n"}'
# 80 443 8404
```

From outside the cluster, against any node address:

```bash
NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -i http://$NODE/                     # 301 → https
curl -ik https://$NODE/
curl -s http://$NODE:8404/healthz
```

## What to know

- **One HAProxy per node, and nothing else on those ports.** Two pods cannot bind the same node port.
  The `hostPort` mirroring makes that a scheduling failure (`Pending`, "node(s) didn't have free
  ports") rather than a container that starts and cannot listen — but if something outside Kubernetes
  already holds 80 on the node, you find out at runtime.
- **`NET_BIND_SERVICE` is the whole reason low ports work here.** Drop it and HAProxy exits with
  `cannot bind socket`. It is a much smaller grant than `privileged: true`, which is never needed for
  this.
- **NetworkPolicies do not apply to hostNetwork pods.** The chart refuses `networkPolicy.enabled`
  together with `hostNetwork.enabled` rather than create a policy that enforces nothing. Filter at the
  node instead — a firewall, or `acl` rules in the configuration itself.
- **The node's network is not the pod network.** `src` in the configuration is the real client
  address, which is exactly what you want at the edge, and something a `Service` of type LoadBalancer
  hides unless `externalTrafficPolicy: Local`.
- **Rolling the DaemonSet takes a node out of rotation.** `maxUnavailable: 1` plus a health check at
  whatever sits in front (DNS, a VIP, an external load balancer) is what keeps the rollout invisible.
- **Consider whether you want an Ingress controller instead.** If the routing rules are meant to come
  from `Ingress` objects rather than from a file you maintain, the
  [HAProxy Kubernetes Ingress Controller](https://github.com/haproxytech/kubernetes-ingress) is the
  right tool; this chart deliberately does not watch the API.
