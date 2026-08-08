# Production cluster — spread, sized, watched

Everything the shorter scenarios leave at their defaults: hard anti-affinity, zone spread, an
external Secret, a metrics exporter, tuned probes and memory sized against the container limit
rather than hoped at.

Six pods across three zones, three masters with one replica each.

## Values

```yaml
# values-production.yaml
mode: cluster
replicaCount: 6

image:
  repository: redis
  # Pinned. A Redis major is not always a drop-in replacement.
  tag: "8.2.8"
  pullPolicy: IfNotPresent

cluster:
  replicas: 1
  init:
    enabled: true
    waitTimeoutSeconds: 600
    resources:
      requests:
        cpu: 50m
        memory: 64Mi

auth:
  enabled: true
  # Owned by an external secret manager. The chart reads the password from this
  # Secret and never writes one of its own.
  existingSecret: redis-credentials
  existingSecretPasswordKey: password

config:
  overrides:
    # Two thirds of the memory limit. Redis accounts for the dataset; the
    # allocator's fragmentation and the client output buffers sit on top, and a
    # maxmemory equal to the limit gets the pod OOM-killed instead of refusing.
    maxmemory: 5gb
    # Data you cannot recompute: refuse the write, do not evict it.
    maxmemory-policy: noeviction
    # AOF with per-second fsync: at most one second of writes lost on a crash,
    # at a cost the event loop does not feel.
    appendonly: "yes"
    appendfsync: everysec
    # A replica that falls too far behind is rebuilt from a full sync, which is
    # expensive. A larger backlog buys a partial resync instead.
    repl-backlog-size: 128mb
    repl-backlog-ttl: 3600
    # Slow commands are the ones you find out about at 3am.
    slowlog-log-slower-than: 10000
    slowlog-max-len: 256
    # A client that stops reading must not be allowed to grow a buffer without
    # bound — that is how one bad consumer takes the instance down.
    timeout: 300
  extraConfig: |
    # Repeated directives go here; a map cannot hold the same key twice.
    save 900 1
    save 300 10
    client-output-buffer-limit normal 0 0 0
    client-output-buffer-limit replica 512mb 128mb 60
    client-output-buffer-limit pubsub 64mb 16mb 60

persistence:
  enabled: true
  size: 50Gi
  # Prefer a class with volumeBindingMode: WaitForFirstConsumer, so the volume
  # is provisioned where the pod is actually scheduled.
  storageClassName: fast-ssd
  accessModes:
    - ReadWriteOnce

statefulSet:
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate
  terminationGracePeriodSeconds: 120
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

# Replaces the chart's soft default. Required rather than preferred: two members
# of one shard on one node share that node's failure, which is exactly what the
# replica exists to prevent. Pods stay Pending when there are not enough nodes —
# the honest failure.
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: redis
            app.kubernetes.io/instance: redis

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: redis
        app.kubernetes.io/instance: redis

resources:
  requests:
    cpu: "1"
    memory: 8Gi
  limits:
    # No CPU limit: throttling a single-threaded event loop shows up directly as
    # command latency, and Redis cannot use more than ~2 cores anyway without
    # io-threads.
    memory: 8Gi

# Loading a 50Gi AOF takes minutes. 60 × 10s is the budget before the pod is
# declared failed — liveness and readiness do not run until this passes.
startupProbe:
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 60

livenessProbe:
  initialDelaySeconds: 20
  periodSeconds: 10
  failureThreshold: 6
  # Catches the node that answers PING while it has lost the cluster: still in
  # the service, returning CLUSTERDOWN to every client. It cannot help a
  # cluster-wide outage — the state is `fail` everywhere at once and every pod
  # restarts — so set it false if you would rather be paged than restarted.
  checkClusterState: true

readinessProbe:
  initialDelaySeconds: 10
  periodSeconds: 10
  failureThreshold: 6
  checkClusterState: true

sidecars:
  - name: metrics
    image: oliver006/redis_exporter:v1.67.0
    ports:
      - name: metrics
        containerPort: 9121
    env:
      - name: REDIS_ADDR
        value: "redis://localhost:6379"
      - name: REDIS_PASSWORD
        valueFrom:
          secretKeyRef:
            name: redis-credentials
            key: password
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
          - ALL
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        memory: 128Mi

podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9121"
  prometheus.io/path: "/metrics"
```

## Install

```bash
kubectl -n redis create secret generic redis-credentials \
  --from-literal=password="$(openssl rand -base64 32)"

helm install redis oci://ghcr.io/willbrid/charts/redis \
  --version 0.1.0 \
  --namespace redis --create-namespace \
  --values values-production.yaml

kubectl -n redis rollout status statefulset/redis --timeout=10m
helm test redis --namespace redis
```

## Verify the guarantees you configured

```bash
export PW=$(kubectl -n redis get secret redis-credentials -o jsonpath='{.data.password}' | base64 -d)

# every slot assigned, state ok
kubectl -n redis exec redis-0 -- redis-cli -a "$PW" cluster info | grep -E 'cluster_state|slots_assigned'

# masters and replicas on different nodes, and spread over zones
kubectl -n redis get pods -o custom-columns=\
'NAME:.metadata.name,NODE:.spec.nodeName,ZONE:.metadata.labels.topology\.kubernetes\.io/zone'

# no replica is on the same node as its master
kubectl -n redis exec redis-0 -- redis-cli -a "$PW" cluster nodes

# memory headroom
kubectl -n redis exec redis-0 -- redis-cli -a "$PW" info memory | \
  grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'

# the exporter is answering
kubectl -n redis exec redis-0 -c metrics -- wget -qO- localhost:9121/metrics | head
```

## The metrics worth alerting on

| Metric | Why |
|---|---|
| `redis_cluster_state` | 0 means the cluster has lost a majority or a slot range — everything else is secondary |
| `redis_memory_used_bytes` / `redis_memory_max_bytes` | Above ~85% with `noeviction` means writes are about to start failing |
| `redis_connected_clients` vs `maxclients` | Connection exhaustion looks like a Redis outage from the application side |
| `redis_master_link_up` | A replica not following its master is a replica that cannot take over |
| `redis_rdb_last_bgsave_status` / `redis_aof_last_write_status` | A persistence failure Redis reports and nothing else notices |
| `redis_commands_duration_seconds_total` rate | The single-threaded loop's saturation, better than CPU% |

## What to know

- **`requiredDuringScheduling` means pods stay Pending** when there are fewer nodes than pods. That
  is deliberate: a `preferred` rule quietly co-locates a master and its replica and halves your
  fault tolerance without saying so.
- **`maxmemory` is not `resources.limits.memory`.** Leave a third for fragmentation, replication
  buffers and the `BGSAVE` fork. `mem_fragmentation_ratio` above 1.5 means you left too little.
- **AOF and RDB are not alternatives here.** `appendonly yes` bounds the loss to a second; the `save`
  lines keep an RDB around, which is what a restore and a full resync are fastest from.
- **A rolling update restarts one pod at a time**, and each one reloads its dataset from disk. Six
  pods × a minute of AOF loading is the real duration of an upgrade — the PDB and the startup probe
  are what keep it safe rather than fast.
- **Scaling is a reshard, not a `--set`.** New pods own no slots until `redis-cli --cluster reshard`
  moves them. See the chart README's *Scaling* section.
- Backups are the missing piece here — add the `backup` block from
  [Scheduled backups](05-backup-to-object-storage.md), and restore-test it once.
