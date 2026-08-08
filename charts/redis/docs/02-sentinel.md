# Sentinel — one master, two replicas, automatic failover

One writable instance, replicas following it, and a sentinel beside each of them that elects a new
master when the current one dies. Scales reads and survives losing a node; it does **not** scale
writes, since every write still goes to a single instance.

Pick this when the dataset fits in one instance and your clients are not cluster-aware — which
covers most Redis use. Pick [cluster mode](01-cluster-quickstart.md) when it does not.

## Values

```yaml
# values-sentinel.yaml
mode: sentinel

# Three or more, preferably odd. A failover needs a majority of the sentinels,
# and two sentinels have no majority left to lose one from.
replicaCount: 3

image:
  repository: redis
  tag: "8.2.8"
  pullPolicy: IfNotPresent

sentinel:
  # The name clients ask for. Changing it on an existing release means changing
  # every client, so pick it once.
  masterSet: mymaster
  port: 26379
  # Empty means a strict majority of replicaCount — the only value that cannot
  # elect a master on both sides of a network partition. Lower it and you are
  # choosing availability over that guarantee, knowingly.
  quorum: ""
  service:
    type: ClusterIP

auth:
  enabled: true
  password: ""      # generated on first install, kept across upgrades

config:
  overrides:
    maxmemory: 2gb
    maxmemory-policy: noeviction

  # The sentinel process has its own configuration, and its own override map.
  sentinelOverrides:
    # How long the master must be unreachable before sentinels call it down.
    # A failover is never faster than this; lowering it trades speed for false
    # positives on a busy or briefly partitioned network.
    down-after-milliseconds: 5000
    # How long a failover may take before another sentinel may retry it.
    failover-timeout: 60000

persistence:
  enabled: true
  size: 20Gi
  storageClassName: ""

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

resources:
  requests:
    cpu: 500m
    memory: 3Gi
  limits:
    memory: 3Gi
```

## Install

```bash
helm install redis oci://ghcr.io/willbrid/charts/redis \
  --version 0.1.0 \
  --namespace redis --create-namespace \
  --values values-sentinel.yaml

kubectl -n redis rollout status statefulset/redis
helm test redis --namespace redis
```

## Connect

A sentinel-aware client is given the **sentinel** service and the master name, and asks who the
master is before every connection:

```
sentinels: redis-sentinel.redis.svc.cluster.local:26379
master set: mymaster
password: <from the secret>
```

```python
# redis-py
from redis.sentinel import Sentinel
s = Sentinel([("redis-sentinel.redis.svc.cluster.local", 26379)],
             sentinel_kwargs={"password": PW})
master  = s.master_for("mymaster", password=PW)   # writes
replica = s.slave_for("mymaster", password=PW)    # reads
```

Ask by hand:

```bash
export PW=$(kubectl -n redis get secret redis -o jsonpath='{.data.redis-password}' | base64 -d)

kubectl -n redis exec redis-0 -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
kubectl -n redis exec redis-0 -- \
  redis-cli -p 26379 sentinel master mymaster
```

## Test a failover

```bash
# who is master now?
kubectl -n redis exec redis-0 -- redis-cli -p 26379 sentinel get-master-addr-by-name mymaster

# kill it
kubectl -n redis delete pod redis-0

# within down-after-milliseconds + election, a different pod answers
sleep 15
kubectl -n redis exec redis-1 -- redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
kubectl -n redis exec redis-1 -- redis-cli -a "$PW" info replication | grep role
```

## What to know

- **The regular service is wrong for writes.** `redis.redis.svc.cluster.local:6379` load-balances
  across master *and* replicas; replicas are read-only, so writes hitting one fail. Use it for reads,
  and find the master through the sentinel service.
- **The master is not always pod 0.** After the first failover it is whichever pod was elected, and
  it stays there. Anything that assumes `redis-0` is the master breaks the first time it matters.
- **Sentinel runs as a sidecar in every Redis pod**, not as a set of its own. One sentinel per
  instance, sharing its fate — a lost node takes down one of each, which keeps the two majorities
  aligned.
- **`replica-serve-stale-data yes` is set in the shipped configuration**, so replicas keep answering
  reads while the master is down. `readinessProbe.requireMasterLink: true` undoes that on the
  Kubernetes side by pulling replicas out of the service during a failover — turn it on only when
  serving a stale read is worse than serving none.
- **Writes in flight during a failover are lost.** Sentinel promotes the most up-to-date replica it
  can find, not necessarily one that has everything. `min-replicas-to-write` bounds this at the cost
  of refusing writes when replicas fall behind.
- **Three pods, three sentinels, quorum 2.** Scaling to 5 raises the quorum to 3 and tolerates two
  failures. Even counts buy nothing.
