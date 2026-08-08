# Collecting container logs from every node

The classic log shipper: one pod per node, tailing `/var/log/containers/*.log`, enriching each
record with the pod, namespace and labels it came from, and forwarding to Loki. This is what most
people install Fluent Bit for.

Two things this needs beyond the values: **RBAC** for the `kubernetes` filter, which queries the API
server, and **host mounts** for the log files.

## RBAC — create this first

The chart creates a ServiceAccount but no roles. Without them the `kubernetes` filter gets `403` on
every lookup and silently ships unenriched records.

```yaml
# rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentbit
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentbit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentbit
subjects:
  - kind: ServiceAccount
    name: fluentbit          # the chart fullname
    namespace: logging
```

```bash
kubectl create namespace logging
kubectl apply -f rbac.yaml
```

## Values

```yaml
# values-daemonset.yaml
# One pod per node. replicaCount and autoscaling are ignored — the chart
# rejects autoscaling.enabled with this kind rather than pretending.
kind: DaemonSet

image:
  repository: fluent/fluent-bit
  tag: "5.0.9"
  pullPolicy: IfNotPresent

command:
  - "/fluent-bit/bin/fluent-bit"

configMountPath: /fluent-bit/etc
configFileName: fluent-bit.conf

# The token is what the kubernetes filter authenticates with.
serviceAccount:
  create: true
  automount: true

# A node collector tails files; it receives nothing over the network, so only
# the monitoring port is published.
service:
  type: ClusterIP
  ports:
    - name: health
      port: 2020
      targetPort: 2020
      protocol: TCP

secret:
  LOKI_BEARER_TOKEN: "changeme"

configmap:
  LOKI_HOST: "loki.logging.svc.cluster.local"
  FLB_LOG_LEVEL: "info"

volumes:
  # The log files themselves. /var/log/containers holds symlinks into
  # /var/log/pods, which is why both are mounted.
  - name: varlog
    hostPath:
      path: /var/log
  # Where the tail plugin remembers how far it read. On a hostPath so the
  # positions survive a pod restart — an emptyDir here means every restart
  # re-reads every file from the beginning and duplicates the logs.
  - name: state
    hostPath:
      path: /var/lib/fluentbit-state
      type: DirectoryOrCreate

volumeMounts:
  - name: varlog
    mountPath: /var/log
    readOnly: true
  - name: state
    mountPath: /var/flb-state

# Node logs matter most on the nodes nobody schedules workloads onto.
tolerations:
  - operator: Exists

config: |
  [SERVICE]
      daemon        Off
      flush         1
      log_level     ${FLB_LOG_LEVEL}
      http_server   On
      http_listen   0.0.0.0
      http_port     2020
      health_check  On
      parsers_file  custom_parsers.conf

  [INPUT]
      name              tail
      tag               kube.*
      path              /var/log/containers/*.log
      # Without this, Fluent Bit tails its own log while writing to stdout:
      # every record is re-ingested, nested into the next one, and the pod
      # burns CPU growing the file exponentially.
      exclude_path      /var/log/containers/*fluentbit*.log
      parser            cri
      db                /var/flb-state/flb_kube.db
      mem_buf_limit     10MB
      skip_long_lines   On
      refresh_interval  10

  [FILTER]
      name                kubernetes
      match               kube.*
      kube_url            https://kubernetes.default.svc:443
      kube_tag_prefix     kube.var.log.containers.
      merge_log           On
      keep_log            Off
      k8s-logging.parser  On
      k8s-logging.exclude On
      labels              On
      annotations         Off

  # Loki wants a small, bounded set of labels. Everything else stays in the
  # record body — a label per pod name is how a Loki install falls over.
  [OUTPUT]
      name                   loki
      match                  kube.*
      host                   ${LOKI_HOST}
      port                   3100
      bearer_token           ${LOKI_BEARER_TOKEN}
      labels                 job=fluentbit
      label_keys             $kubernetes['namespace_name'],$kubernetes['container_name']
      auto_kubernetes_labels Off
      line_format            json
      retry_limit            5

parsers:
  fileName: custom_parsers.conf
  content: |
    [PARSER]
        Name        cri
        Format      regex
        Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<message>.*)$
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L%z

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## Install

```bash
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging \
  --values values-daemonset.yaml
```

## Verify

```bash
kubectl -n logging get daemonset fluentbit       # DESIRED must equal your node count

# is the kubernetes filter actually enriching, or silently failing?
kubectl -n logging logs -l app.kubernetes.io/name=fluentbit | grep -i "kubernetes\|403\|token"

# per-plugin counters: records in, records out, retries
kubectl -n logging port-forward svc/fluentbit 2020:2020 &
curl -s localhost:2020/api/v1/metrics | jq '.output'

# and at the far end
curl -s -G http://loki:3100/loki/api/v1/labels
```

## What to know

- **`parser cri` matches containerd and CRI-O**, which is every current cluster. On the old Docker
  runtime the lines are JSON and the parser must be `docker` instead; a mismatch shows up as records
  whose whole line ended up in a single unparsed field.
- **`kube_tag_prefix` must match the tag the tail input builds.** With `tag kube.*` on
  `/var/log/containers/*.log`, the tag becomes `kube.var.log.containers.<file>` — get this wrong and
  the filter cannot extract the pod name, so it enriches nothing while reporting no error.
- **The position database is the difference between a restart and a duplicate flood.** Keep `db` on
  a hostPath. If you must use an `emptyDir`, expect every pod restart to re-ship the retained logs.
- **`tolerations: [operator: Exists]` puts a pod on every node**, tainted control planes included.
  That is usually what you want from a log collector, and it is the one line people forget when logs
  from the control plane go missing.
- **Excluding a namespace** is done with the `grep` filter (`exclude $kubernetes['namespace_name']
  ^(kube-system)$`), not in the tail input — the tail input has no idea what a namespace is.
- For Elasticsearch instead of Loki, swap the `[OUTPUT]` for `name es`, with `host`, `port`,
  `http_user` / `http_passwd` from the Secret, and `suppress_type_name On` on Elasticsearch 8+.
