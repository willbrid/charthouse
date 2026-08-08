# Redis Cluster — 3 masters, one replica each

The default shape of the chart, filled in: six pods, the keyspace sharded across three masters, each
with a replica ready to take over. Scales writes and memory, and survives losing one pod per shard.

Pick this over sentinel when the dataset outgrows one instance or the write rate does. Pick
[sentinel](02-sentinel.md) when it does not — cluster mode costs you multi-key commands across slots
and every database but 0.

## Values

```yaml
# values-cluster.yaml
mode: cluster

# Must divide into masters and replicas with at least 3 masters: a cluster votes,
# and fewer than three voters cannot form a majority. With cluster.replicas: 1
# the usable sizes are 6, 8, 10, … The chart checks this at render time.
replicaCount: 6

image:
  repository: redis
  tag: "8.2.8"
  pullPolicy: IfNotPresent

cluster:
  # One replica per master. 0 shards without redundancy — losing a pod then
  # loses the slots it owned.
  replicas: 1
  init:
    # Redis nodes do not form a cluster on their own. This Helm hook hands out
    # the 16384 slots once and pairs each replica with a master.
    enabled: true
    waitTimeoutSeconds: 600

auth:
  enabled: true
  # Left empty, the chart generates a password on first install and keeps it
  # across upgrades. Read it back with:
  #   kubectl -n redis get secret redis -o jsonpath='{.data.redis-password}' | base64 -d
  password: ""

config:
  overrides:
    # Must stay below the memory limit — Redis accounts for the dataset, not for
    # the fragmentation and the client buffers around it. Two thirds is a safe
    # starting point.
    maxmemory: 2gb
    # A cluster holding data you cannot recompute should refuse writes rather
    # than evict silently. Use allkeys-lru only for a cache.
    maxmemory-policy: noeviction

persistence:
  enabled: true
  size: 20Gi
  storageClassName: ""      # "" takes the cluster default StorageClass

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

resources:
  requests:
    cpu: 500m
    memory: 3Gi
  limits:
    # No CPU limit on purpose: throttling a single-threaded event loop shows up
    # directly as command latency.
    memory: 3Gi
```

## Install

```bash
helm install redis oci://ghcr.io/willbrid/charts/redis \
  --version 0.1.0 \
  --namespace redis --create-namespace \
  --values values-cluster.yaml

kubectl -n redis rollout status statefulset/redis
helm test redis --namespace redis
```

The `helm test` pod is the real check here: it verifies every one of the 16384 slots is assigned,
which is what "the cluster formed" actually means.

## Connect

```bash
export PW=$(kubectl -n redis get secret redis -o jsonpath='{.data.redis-password}' | base64 -d)

kubectl -n redis exec -it redis-0 -- redis-cli -a "$PW" cluster info
kubectl -n redis exec -it redis-0 -- redis-cli -a "$PW" cluster nodes

# a cluster-aware client follows the redirects itself
kubectl -n redis exec -it redis-0 -- redis-cli -c -a "$PW" set foo bar
kubectl -n redis exec -it redis-0 -- redis-cli -c -a "$PW" get foo
```

From an application, `redis://redis.redis.svc.cluster.local:6379` — with a **cluster-aware** client
(`redis-py` `RedisCluster`, Lettuce `RedisClusterClient`, `go-redis` `ClusterClient`). A plain client
gets `MOVED` on most keys and fails.

## Verify the shape is the one you asked for

```bash
# three masters, three replicas, each replica pointing at a different master
kubectl -n redis exec redis-0 -- redis-cli -a "$PW" cluster nodes | \
  awk '{print $2, $3, $4}'

# every slot covered
kubectl -n redis exec redis-0 -- redis-cli -a "$PW" cluster info | grep -E 'cluster_state|cluster_slots_assigned'
# cluster_state:ok
# cluster_slots_assigned:16384

# pods spread over nodes — the chart applies a soft anti-affinity by default
kubectl -n redis get pods -o wide
```

## What to know

- **The address clients are redirected to is a DNS name, not a pod IP.** That is
  `cluster-preferred-endpoint-type hostname` in the shipped configuration, and it is the one line
  that makes a Redis Cluster survive rescheduling on Kubernetes. If you replace the configuration
  wholesale with `config.content`, carry it over — `helm test` fails loudly when you do not.
- **`nodes.conf` is on the volume, and it is the node's identity.** It carries the node id, its
  slots and its view of its peers. A pod that loses it comes back as a stranger the cluster has
  never met — which is why `persistence.enabled: false` is for caches only.
- **The PVCs survive `helm uninstall`.** Deleting a Redis cluster's data is a separate, deliberate
  act: `kubectl -n redis delete pvc -l app.kubernetes.io/instance=redis`.
- **Scaling is not `--set replicaCount`.** Adding pods gives you nodes that own no slots; the slots
  have to be moved onto them with `redis-cli --cluster reshard`. See the chart README's *Scaling*
  section.
- **The soft anti-affinity is a preference.** Once you have as many nodes as pods, make it a
  requirement: two members of one shard on one node share that node's failure, which is exactly what
  the replica was there to prevent — see [Production cluster](06-production-cluster.md).
