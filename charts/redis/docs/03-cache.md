# A pure cache — bounded memory, eviction, no persistence

Redis holding only data you can recompute: session fragments, rendered pages, query results.
Everything is on an `emptyDir`, memory is capped, and the oldest keys are evicted rather than writes
refused. Losing a pod costs a cache miss, nothing more.

This is the one shape where `persistence.enabled: false` is the right answer.

## Values

```yaml
# values-cache.yaml
mode: cluster

# Three masters, no replicas. Losing a pod loses the slots it held — acceptable
# when every value can be recomputed, and it halves the pod count.
replicaCount: 3

cluster:
  replicas: 0
  init:
    enabled: true

image:
  repository: redis
  tag: "8.2.8"

auth:
  enabled: true
  password: ""

config:
  overrides:
    # Below the memory limit, with room for fragmentation and client buffers.
    maxmemory: 3gb
    # The line that makes this a cache: evict the least recently used key
    # instead of refusing the write.
    maxmemory-policy: allkeys-lru
    # Nothing on disk, so nothing to write.
    appendonly: "no"
    # Freeing memory in a background thread keeps a mass eviction from stalling
    # the event loop.
    lazyfree-lazy-eviction: "yes"
    lazyfree-lazy-expire: "yes"
  extraConfig: |
    # Disable RDB snapshots entirely. A repeated directive, so it goes here
    # rather than in the overrides map.
    save ""

# No PVC at all. nodes.conf lives on the emptyDir with everything else, so a
# restarted pod comes back as a node the cluster has never met — it is
# re-added by the cluster, empty, and refills from misses.
persistence:
  enabled: false

# A cache tolerates losing a pod, so let drains proceed.
podDisruptionBudget:
  enabled: false

resources:
  requests:
    cpu: 500m
    memory: 4Gi
  limits:
    memory: 4Gi
```

## Install

```bash
helm install redis-cache oci://ghcr.io/willbrid/charts/redis \
  --version 0.1.0 \
  --namespace cache --create-namespace \
  --values values-cache.yaml
```

Note the release name: the chart pins `fullnameOverride: "redis"`, so two releases cannot share a
namespace. Give the cache its own namespace, or its own `fullnameOverride`.

## Verify it evicts rather than refuses

```bash
export PW=$(kubectl -n cache get secret redis -o jsonpath='{.data.redis-password}' | base64 -d)

kubectl -n cache exec redis-0 -- redis-cli -a "$PW" config get maxmemory maxmemory-policy

# fill it and watch keys leave
kubectl -n cache exec redis-0 -- redis-cli -a "$PW" -c debug populate 1000000
kubectl -n cache exec redis-0 -- redis-cli -a "$PW" info stats | grep evicted_keys
kubectl -n cache exec redis-0 -- redis-cli -a "$PW" info memory | grep -E 'used_memory_human|maxmemory_human'

# the numbers that tell you whether the cache is worth its memory
kubectl -n cache exec redis-0 -- redis-cli -a "$PW" info stats | grep keyspace_
```

## What to know

- **`maxmemory` must be well below the container limit.** Redis counts the dataset; the allocator's
  fragmentation and the client output buffers sit on top. A `maxmemory` equal to the limit gets the
  pod OOM-killed instead of evicting, which is the failure this configuration exists to avoid.
- **`allkeys-lru` evicts any key; `volatile-lru` only evicts keys with a TTL.** With `volatile-*`
  and no TTLs set, Redis has nothing to evict and starts refusing writes — a cache that behaves like
  a database, at the worst possible moment.
- **No replicas means no failover, by design.** Losing a pod loses a third of the keyspace until
  Kubernetes reschedules it. If a cold third of the cache is a problem, you want
  [the replicated cluster](01-cluster-quickstart.md) with `maxmemory-policy: allkeys-lru`.
- **Restarted pods rejoin empty.** With no volume, `nodes.conf` is gone; the cluster re-admits the
  pod and it refills from misses. Expect a latency bump, not an outage.
- **Watch `evicted_keys` and the hit ratio**, not memory usage: at steady state a cache with
  eviction on is always near `maxmemory`, so memory tells you nothing. `keyspace_hits` versus
  `keyspace_misses` is what says whether it is sized right.
