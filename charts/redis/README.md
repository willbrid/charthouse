# redis

A production Helm chart for **Redis OSS**, in **cluster** mode or **sentinel** mode.

- Image: **[hub.docker.com/_/redis](https://hub.docker.com/_/redis)** — the official image, `redis:8.2.8` by default
- Documentation: **[redis.io/docs/latest/operate/oss_and_stack](https://redis.io/docs/latest/operate/oss_and_stack/)**

Deployed as a single **StatefulSet**. Sizing comes from `replicaCount`; everything
that follows from it — node addresses, the master/replica split, the sentinel
quorum, the bootstrap of the cluster, which pod follows which — is derived by the
chart rather than asked of you.

---

## Contents

- [Choosing a mode](#choosing-a-mode)
- [Quick start](#quick-start)
- [Example scenarios](#example-scenarios)
- [What the chart derives](#what-the-chart-derives)
- [Configuration](#configuration)
- [Cluster mode](#cluster-mode)
- [Sentinel mode](#sentinel-mode)
- [Probes](#probes)
- [Authentication](#authentication)
- [Injecting files](#injecting-files)
- [Storage](#storage)
- [Backup and restore](#backup-and-restore)
- [Recommended production configuration](#recommended-production-configuration)
- [Availability](#availability)
- [Values](#values)
- [Verifying an install](#verifying-an-install)
- [CI scenarios](#ci-scenarios)
- [Known limitations](#known-limitations)

---

## Choosing a mode

Neither mode is a superset of the other, and the choice is not reversible by an
upgrade — the on-disk layout, the addressing and the client contract all differ.
Switching means installing a second release and migrating the data.

| | **cluster** | **sentinel** |
|---|---|---|
| Topology | keyspace sharded across N masters | one master, N-1 replicas |
| Scales writes | yes, by adding shards | no, every write goes to one instance |
| Scales reads | yes | yes, across the replicas |
| Scales memory | yes, the dataset is split | no, every node holds everything |
| Survives losing a node | yes, if `cluster.replicas ≥ 1` | yes |
| Failover | automatic, by the masters voting | automatic, by the sentinels voting |
| Client requirement | cluster-aware | sentinel-aware |
| Multi-key commands | same slot only | unrestricted |
| Databases | `0` only | 16 |
| Minimum pods | 3 masters, so 3 or 6 | 3 |

Rule of thumb: if the dataset fits in one instance and you need `MULTI`, Lua
across keys or `SELECT`, use **sentinel**. If it does not fit, or writes are the
bottleneck, use **cluster** and give the clients a cluster-aware driver.

---

## Quick start

```bash
# Redis Cluster: 3 masters, 1 replica each
helm install redis oci://ghcr.io/willbrid/charts/redis --version 0.1.0 \
  --namespace redis --create-namespace \
  --set mode=cluster --set replicaCount=6 --set cluster.replicas=1 \
  --set auth.enabled=true

# Sentinel: 1 master, 2 replicas, 3 sentinels
helm install redis oci://ghcr.io/willbrid/charts/redis --version 0.1.0 \
  --namespace redis --create-namespace \
  --set mode=sentinel --set replicaCount=3 \
  --set auth.enabled=true
```

Then check that the topology actually formed — pod readiness will not tell you:

```bash
helm test redis -n redis --logs
```

---

## Example scenarios

Complete values files, one per installation shape, in [`docs/`](docs/). Each page carries the values,
the install command and how to check the result.

| # | Scenario | What it covers |
|---|---|---|
| 1 | [Redis Cluster](docs/01-cluster-quickstart.md) | 3 masters with a replica each, bootstrap job, cluster-aware clients |
| 2 | [Sentinel](docs/02-sentinel.md) | One master, automatic failover, and which address clients must use for writes |
| 3 | [Pure cache](docs/03-cache.md) | `maxmemory` with eviction, no PVC — the one place `persistence.enabled: false` is right |
| 4 | [ACLs and TLS](docs/04-acl-and-tls.md) | Per-application users through `extraFiles`, TLS ports, and the `default` user trap |
| 5 | [Scheduled backups](docs/05-backup-to-object-storage.md) | The backup CronJob on a real PVC, shipping off-cluster, and restoring |
| 6 | [Production cluster](docs/06-production-cluster.md) | Hard anti-affinity, zone spread, external Secret, exporter sidecar, tuned probes |

---

## What the chart derives

| Derived | From | Notes |
|---|---|---|
| Pod addresses | `replicaCount`, headless service | `redis-0.redis-headless.<ns>.svc.<domain>` |
| `cluster-announce-hostname` | the pod's own name | per pod, at startup |
| `replica-announce-ip` | the pod's own name | per pod, at startup |
| Number of masters | `replicaCount / (cluster.replicas + 1)` | validated ≥ 3 |
| Slot assignment | the bootstrap job | `redis-cli --cluster create` |
| `replicaof` | asking sentinel | per pod, at startup |
| `sentinel monitor` | asking the other sentinels | per pod, at startup |
| Sentinel quorum | `⌊replicaCount / 2⌋ + 1` | override with `sentinel.quorum` |
| Cluster bus port | `service.port + 10000` | fixed by Redis |
| `dir` | `persistence.mountPath` | so the data lands on the volume |
| Anti-affinity | selector labels | soft, unless you set `affinity` |

A topology that cannot work is rejected at render time rather than installed:
an uneven split into shards, fewer than three masters, fewer than three
sentinels, a quorum outside `1..replicaCount`, a port that leaves no room for
the cluster bus, a `config.overrides` key the chart owns.

---

## Configuration

Redis is configured by a file, not by values. A production `redis.conf` runs to
several hundred lines whose ordering matters, and it belongs somewhere it can be
read and reviewed as one thing.

The file the pod reads is assembled from four layers. Redis keeps the **last**
occurrence of a directive, so each layer overrides the one above it:

| # | Layer | Where | Rendered with `tpl` |
|---|---|---|---|
| 1 | `config.file` | `files/redis.conf` | yes |
| 2 | `config.modeFile` | `files/mode-cluster.conf` / `files/mode-sentinel.conf` | yes |
| 3 | `config.overrides` (map) and `config.extraConfig` (raw) | `values.yaml` | `extraConfig` only |
| 4 | the chart | written per pod at startup | — |

`config.content` replaces layers 1 **and** 2 with a configuration of your own —
see [Bringing your own file](#bringing-your-own-file).

Layers 1–3 are rendered into a ConfigMap. Layer 4 is appended by
`start-redis.sh` inside the pod, because it cannot exist earlier — it is this
pod's DNS name, the current master, the mount path of its volume, the password
read out of a Secret.

### Directives the chart owns

Setting any of these in `config.overrides` fails the install rather than being
silently overridden:

```
dir                        port                      unixsocket
cluster-enabled            cluster-config-file       cluster-announce-hostname
cluster-announce-ip        cluster-announce-port     cluster-announce-bus-port
replicaof / slaveof        replica-announce-ip       replica-announce-port
requirepass                masterauth
```

### Making changes

```yaml
config:
  # A map, for the common case
  overrides:
    maxmemory: 4gb
    maxmemory-policy: allkeys-lru
    io-threads: 4

  # Raw text, for directives that legitimately repeat — a map cannot hold the
  # same key twice
  extraConfig: |
    save 900 1
    save 300 10
    rename-command FLUSHALL ""
```

> Booleans are converted to `yes`/`no`. Writing `appendonly: yes` in values.yaml
> gives YAML the boolean `true`, and `appendonly true` is a configuration error
> Redis only reports at startup — so the chart translates it back.

### Bringing your own file

Three ways, in increasing order of how much they take over.

**`--set-file config.extraConfig`** — append a file, keeping the chart's base:

```bash
helm install redis charts/redis --set-file config.extraConfig=./my-tuning.conf
```

It lands as layer 3, so every directive it sets wins. Directives it does not
mention keep the chart's values, which is usually what you want from a file of
tuning.

**`--set-file config.content`** — replace layers 1 and 2 outright:

```bash
helm install redis charts/redis --set-file config.content=./my-redis.conf
# and, in sentinel mode, optionally
#   --set-file config.sentinelContent=./my-sentinel.conf
```

Layers 3 and 4 still apply on top. What the file does not say, **nothing else
says either** — read `files/redis.conf` and `files/mode-<mode>.conf` before
replacing them, and carry over what your deployment needs from them. In cluster
mode that means at least:

```
cluster-preferred-endpoint-type hostname
```

Leave it out and the cluster redirects clients to pod IPs. `helm test` fails on
it, by inspecting a real `MOVED` redirect:

```
==> the addresses handed to clients
  FAIL  redirects carry '10.244.0.107:6379', which is a pod address rather than a name.
        Clients cache it, and a reschedule hands it to something else.
        Is 'cluster-preferred-endpoint-type hostname' still in the configuration?
```

`config.sentinelContent` is independent: replacing the server's configuration
leaves sentinel's coming from `files/sentinel.conf`.

**`config.existingConfigMap`** — a ConfigMap the chart does not manage:

```bash
kubectl create configmap my-redis-config \
  --from-file=redis.conf=./my-redis.conf \
  --from-file=sentinel.conf=./my-sentinel.conf   # sentinel mode only
```

```yaml
config:
  existingConfigMap: my-redis-config
  redisKey: redis.conf
  sentinelKey: sentinel.conf
```

This replaces layers 1–3 entirely — `file`, `modeFile`, `content`, `overrides`
and `extraConfig` are all ignored. Layer 4 still applies. It is mutually
exclusive with `config.content`, and setting both fails the install rather than
silently preferring one.

Forking the chart and editing `files/redis.conf` remains the option that keeps
the comments and the review history with the configuration.

> Every one of these is rendered with `tpl`, which is what lets a file refer to
> `{{ .Values.auth.password }}`. The other side of that: a literal `{{` in an
> injected file breaks the render. It costs nothing in a `redis.conf` and matters
> for a Lua script.

---

## Cluster mode

### Bootstrap

Redis nodes started with `cluster-enabled yes` do not form a cluster. Each comes
up as a cluster of one, owning no slots and knowing nobody, and waits there
indefinitely. Something has to hand out the 16384 slots and pair each replica
with a master, exactly once.

That is the `redis-cluster-init` Job, a Helm hook running after install and
after upgrade. It waits for every pod to answer `PING`, checks whether a cluster
already exists, and creates one only if not:

```bash
kubectl logs -n redis job/redis-cluster-init
```

It is idempotent — it inspects before it acts — so the extra run on each upgrade
costs a few seconds. A successful job is cleaned up; a failed one is left in
place, because its logs are the only account of what went wrong.

Set `cluster.init.enabled=false` to bootstrap by hand instead.

### Addressing, and why it is the thing that matters

A Redis Cluster has no proxy in front of it. Every node hands the client the
address of whichever node owns the slot, and the client connects there directly.
So **the addresses the nodes gossip are the addresses your clients dial** — and
a pod IP is not one of them. It changes on every reschedule, and the client that
cached it is now talking to whatever inherited the address.

The chart sets, per pod:

```
cluster-announce-hostname redis-0.redis-headless.<ns>.svc.<domain>
cluster-preferred-endpoint-type hostname
```

The second line is what makes the first one reach clients; without it the
hostname is gossiped and then ignored. Both need Redis ≥ 7.0, which is part of
why this chart targets 8.2.

`helm test` checks it, so a regression here fails loudly:

```
==> the addresses handed to clients
  ok    nodes announce their DNS names
```

### Scaling

The bootstrap job creates a cluster; it does not grow one. Raising
`replicaCount` gives you running, idle nodes that hold no slots and receive no
traffic. Growing means moving data, which is not something to do blindly:

```bash
# Add the new node to the cluster
kubectl exec -n redis redis-0 -c redis -- redis-cli --cluster add-node \
  redis-6.redis-headless.redis.svc.cluster.local:6379 \
  redis-0.redis-headless.redis.svc.cluster.local:6379

# Move slots onto it
kubectl exec -n redis redis-0 -c redis -- redis-cli --cluster rebalance \
  redis-0.redis-headless.redis.svc.cluster.local:6379 --cluster-use-empty-masters
```

Shrinking is the same in reverse: `--cluster reshard` the slots away, then
`--cluster del-node`, then lower `replicaCount`. The job says as much in its
logs when it notices more pods than cluster members.

---

## Sentinel mode

### Topology

One sentinel per Redis instance, running as a **sidecar in the same pod**. They
share a fate: a lost node takes down one of each, which keeps the two majorities
aligned — and keeps the chart to the single StatefulSet it is meant to be.

### Who is the master?

Redis has no memory of this. A replica is told to follow a master at runtime, by
sentinel, and forgets it the moment it restarts. So every pod works the answer
out again on every start, from three sources in order of authority:

1. **A live sentinel.** The authority — it is what decides who leads, and the
   only party that knows about a failover that happened while this pod was down.
   Every sentinel is asked, and an answer naming someone else wins over an
   answer naming us: a failover takes seconds to propagate, and a stale answer
   naming the pod that just died is exactly the answer that would bring a second
   master back up.
2. **The sentinel state file on the volume.** Sentinel rewrites its
   configuration as it learns the topology, and the chart keeps that file on the
   PersistentVolume for this reason. It covers the case source 1 cannot: the
   whole set went down at once, so no sentinel is up to be asked.
3. **Pod 0.** What a first install looks like. Any other tie-break would need
   agreement, and there is nobody to agree with yet.

Whatever comes out is validated before it is written — a malformed endpoint in a
stale file would otherwise make Redis refuse to start, turning an old file into
a pod that never comes back.

### Connecting

Point a **sentinel-aware** client at the sentinel service and let it ask:

```yaml
sentinels:
  - redis-sentinel.redis.svc.cluster.local:26379
masterSet: mymaster
```

The client asks any sentinel who currently holds the master role, is told a
per-pod DNS name, and connects there — asking again after a failover.

The `redis` service load-balances across master and replicas alike. That is
right for reads and wrong for writes: a write sent through it lands on a replica
two times out of three and is refused.

### Failover

Verified on a real cluster: deleting the master pod promotes a replica within
about ten seconds, and the deleted pod comes back as a replica of the new
master with its data intact.

```bash
kubectl delete pod redis-0 -n redis

kubectl exec -n redis redis-1 -c sentinel -- \
  redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

A rolling update triggers the same thing once per pod and ends with exactly one
master.

---

## Probes

Every probe runs a script rather than a TCP connect, and **the scripts differ by
mode**, because health does. A socket accepting connections says almost nothing
here: an instance loading a large RDB, or one stuck under memory pressure,
accepts the connection and answers nothing.

| Probe | Question it answers | Both modes | cluster | sentinel |
|---|---|---|---|---|
| `startupProbe` | has it finished coming up? | `PING` | — | — |
| `livenessProbe` | will a restart help? | `PING` | `cluster_state` | — |
| `readinessProbe` | should it get traffic? | `PING` | `cluster_state` | `master_link_status` (opt-in) |

`PING` is interpreted rather than compared: `LOADING`, `MASTERDOWN` and `BUSY`
mean alive-but-not-serving, so liveness passes and readiness does not. Nothing
restarts a container that is busy loading the dataset it was asked to load.

### `cluster_state` in liveness

On by default (`livenessProbe.checkClusterState`). It catches the node that
answers `PING` while having lost the cluster: still in the service, still
serving, and returning `CLUSTERDOWN` to every client that lands on it.

Two things make it safe enough to leave on, and both matter:

- The check is **skipped on a node that is not yet part of a formed cluster**
  (`cluster_known_nodes = 1`). Without that, every pod would restart in a loop
  in the window between install and bootstrap, the job would never find a stable
  set of nodes, and the cluster would never be created at all.
- `failureThreshold × periodSeconds` is a full minute, long enough to ride out
  the state flapping during a failover.

What it cannot be made safe against is a genuine cluster-wide outage: the state
is `fail` on every node at once, so every pod restarts, and a restart does not
bring back the majority that was lost. Set it to `false` if you would rather the
pods stayed up and broken, and be told by an alert instead.

### `master_link_status` in readiness

Off by default (`readinessProbe.requireMasterLink`), and that is a choice rather
than an oversight. The shipped configuration sets `replica-serve-stale-data yes`
so reads keep working while a master is down; turning this on undoes that from
the Kubernetes side, pulling every replica out of the service for the length of
a failover. Turn it on when a stale read is worse than no read.

### Replacing a probe

```yaml
livenessProbe:
  command: ["/bin/sh", "-c", "redis-cli ping | grep -q PONG"]
  periodSeconds: 15
```

Set a probe to `null` to remove it entirely.

---

## Authentication

Off by default, which is the right default for a chart and the wrong one for
production. `protected-mode no` is set in the shipped configuration — in a pod
it protects nothing — so anything that can reach the port has full access,
including `FLUSHALL` and `CONFIG`.

```yaml
auth:
  enabled: true
  password: ""            # empty: generated once, kept across upgrades
  # existingSecret: redis-credentials
  # existingSecretPasswordKey: password
```

The password is mounted from a Secret and written into the configuration at
startup. It never reaches a ConfigMap, a command line or the process table.
Applied as `requirepass`, as `masterauth` so a replica can authenticate to its
master, and as `sentinel auth-pass` so the sentinels can reach what they
monitor. Clients of `redis-cli` inside the chart use `REDISCLI_AUTH`.

Read a generated password back with:

```bash
kubectl get secret redis -n redis -o jsonpath='{.data.redis-password}' | base64 -d
```

### ACLs — one trap worth knowing

A shared password is a poor fit once there is more than one kind of client.
Mount an ACL file and point `aclfile` at it:

```yaml
extraFiles:
  configMap:
    users.acl: |
      user default on >{{ .Values.auth.password }} ~* &* +@all
      user app on >{{ .Values.auth.password }} ~app:* +@read +@write

config:
  overrides:
    aclfile: /etc/redis/files/users.acl
```

**The `default` line is not optional.** Loading an ACL file replaces the whole
user list, `default` included, so a file that stays silent about it hands the
default user back its built-in `nopass` definition and quietly discards
`requirepass`. Everything then starts and nothing replicates:

```
# Unable to AUTH to MASTER: -ERR AUTH <password> called without any
  password configured for the default user.
```

Sentinel does not carry a password of its own in this chart, and the scripts
strip `REDISCLI_AUTH` before talking to it — sending `AUTH` to a server that
never asked for one is an error, and the answer is lost with it.

---

## Injecting files

Arbitrary files, under names of your choosing, mounted in one directory inside
both containers: TLS material, an ACL file, sentinel notification hooks, a Lua
script — anything the configuration refers to by path.

```yaml
extraFiles:
  mountPath: /etc/redis/files

  configMap:
    users.acl: |
      user app on >{{ .Values.auth.password }} ~app:* +@read +@write
    notify.sh: |
      #!/bin/sh
      echo "sentinel event: $*"

  secret:
    redis.crt: |
      -----BEGIN CERTIFICATE-----
      ...
    redis.key: |
      -----BEGIN PRIVATE KEY-----
      ...

  # Group-readable: the files belong to root and are read by uid 999 through
  # fsGroup. Raise to 0550 for scripts sentinel has to execute.
  defaultMode: 0440
```

Both maps are rendered with `tpl`, so a file may refer to values. Both land in
the same directory through a single projected volume, which is why a name may
appear in one or the other but never in both — the chart refuses that at render
time.

Reference them from the configuration by path:

```yaml
config:
  overrides:
    aclfile: /etc/redis/files/users.acl
    tls-cert-file: /etc/redis/files/redis.crt
    tls-key-file: /etc/redis/files/redis.key
```

For volumes that do not fit this shape — a CSI secret store, a large read-only
dataset — use `volumes` and `volumeMounts`, which are passed through verbatim.

---

## Storage

One PersistentVolumeClaim per pod, bound to its ordinal for the life of the set.

```yaml
persistence:
  enabled: true
  size: 8Gi
  storageClassName: ""      # empty: the cluster default
  mountPath: /data
```

It holds the RDB, the AOF, the sentinel state and — in cluster mode —
`nodes.conf`. That last file is the node's **identity**, not merely its data:
its ID, its slots, its view of its peers. A pod that loses it does not rejoin
the cluster, it arrives as a stranger the cluster has never met, and the slots
it held stay unreachable until you repair it by hand.

Prefer a StorageClass with `volumeBindingMode: WaitForFirstConsumer`, so the
volume is provisioned where the pod is actually scheduled.

`persistence.enabled: false` puts everything on an `emptyDir`. That is a cache,
not a database, and the chart says so in its install notes.

By default the PVCs are **retained** when the release is uninstalled — an
accidental `helm uninstall` does not take the data with it. Change that
deliberately:

```yaml
statefulSet:
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete
    whenScaled: Retain
```

---

## Backup and restore

### What is and is not protected

| Failure | Protected by | Backup needed? |
|---|---|---|
| A pod is restarted or rescheduled | AOF on the PersistentVolume | no |
| A node is lost | replication + failover | no |
| A volume is lost | replication | no |
| **`FLUSHALL`, or a bad migration** | nothing | **yes** |
| **The namespace is deleted** | nothing | **yes** |
| **Ransomware, a compromised client** | nothing | **yes** |

Replication is not a backup. A mistaken `FLUSHALL` reaches every replica in
milliseconds, and so does a `DEL` on the wrong key pattern. The only answer is a
copy Redis cannot reach.

### The CronJob

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *"
  target: all               # all | master | replica
  retentionDays: 7

  storage:
    persistentVolumeClaim:
      claimName: redis-backups

  # Runs after each dump, with BACKUP_DIR and BACKUP_FILE set
  postBackupScript: |
    aws s3 cp "$BACKUP_FILE" "s3://my-bucket/redis/" --only-show-errors
```

It runs `redis-cli --rdb`, which asks the instance for a full synchronisation
and writes what comes back, exactly as a replica would. Two consequences worth
knowing:

- the dump is **consistent** — a point-in-time snapshot produced by Redis
  itself, not a copy of a file being written to underneath you. Copying
  `dump.rdb` off the volume gives you neither guarantee;
- it **costs a fork** on the instance it runs against. Hence the 3am default,
  and hence `target`.

Each dump is verified with `redis-check-rdb` before being counted as a success,
and retention only runs when every dump succeeded — a failed run must not be the
thing that deletes the last good backup.

`target`:

- **`all`** — every pod. The only correct choice in cluster mode, where each
  master holds a different share of the keyspace; the chart rejects the others
  there.
- **`master`** — the current master, found by asking sentinel rather than by
  guessing. Which pod leads changes with every failover.
- **`replica`** — every replica, keeping the fork off the instance serving
  writes.

Output layout, one directory per run:

```
/backup/20260806T030000Z/redis-0.rdb
/backup/20260806T030000Z/redis-1.rdb
```

Run one now, without waiting for the schedule:

```bash
kubectl create job -n redis backup-now --from=cronjob/redis-backup
kubectl logs -n redis job/backup-now -f
```

### Where to put the dumps

`backup.storage` takes a volume spec verbatim. The default `emptyDir` is a
placeholder that loses the backup with the pod — which is to say it is not a
backup. Use a PVC on a different StorageClass, an NFS share, or a CSI volume
backed by object storage, and copy off-cluster with `postBackupScript`.

A dump the cluster can delete is not protection against the cluster deleting
things. Prefer a bucket with object-lock or versioning enabled.

### Restoring

**Sentinel mode**, restoring the whole dataset:

```bash
# 1. Stop the writers, then scale the release down
kubectl scale statefulset redis -n redis --replicas=0

# 2. Put the dump in place of pod 0's RDB, on its PVC. Any pod that mounts
#    data-redis-0 will do — a scratch pod with the claim mounted is simplest.
#    The file must be named as `dbfilename` says, dump.rdb by default.

# 3. AOF takes precedence over RDB at load time: if appendonly is on, remove
#    the appendonlydir so Redis reads the RDB you just restored.
rm -rf /data/appendonlydir

# 4. Bring pod 0 back first and let it become the master, then the rest
kubectl scale statefulset redis -n redis --replicas=1
kubectl scale statefulset redis -n redis --replicas=3
```

The replicas resynchronise from the restored master. Do not restore each pod
individually: they will be overwritten by replication anyway.

**Cluster mode** is not a file copy. The slots have to be reassigned along with
the data, so restore into a **new cluster of the same shape** and reimport:

```bash
# Same replicaCount and cluster.replicas as the cluster the dumps came from,
# then, per master, with the node stopped:
redis-check-rdb /backup/<run>/redis-0.rdb    # verify first
# place the file as dump.rdb on that node's volume, start it, and let the
# cluster form with `cluster.init.enabled=true`
```

For a partial restore — a few keys, a single prefix — start a throwaway Redis on
the dump and copy out of it with `redis-cli --scan` and `MIGRATE`. That is far
less disruptive than restoring a whole instance.

> Test the restore. A backup nobody has restored is a hypothesis.

---

## Recommended production configuration

Starting points, not gospel. Both assume a cluster with three or more nodes and
a StorageClass worth writing to.

### Both modes

```yaml
auth:
  enabled: true

persistence:
  enabled: true
  size: 20Gi
  storageClassName: fast-ssd

resources:
  requests:
    cpu: 1
    memory: 8Gi
  limits:
    # No CPU limit: throttling a single-threaded event loop shows up directly
    # as client latency. Request what you need and let it burst.
    memory: 8Gi

config:
  overrides:
    # ~75% of the memory limit. NEVER leave this unset when a limit is in
    # place: Redis grows into the limit and is OOM-killed by the kernel, which
    # no eviction policy can prevent.
    maxmemory: 6gb
    maxmemory-policy: noeviction     # allkeys-lru for a pure cache
    io-threads: 4                    # never above the CPU request

backup:
  enabled: true
  storage:
    persistentVolumeClaim:
      claimName: redis-backups

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: redis
```

Also worth doing, outside the chart: a **NetworkPolicy**. `protected-mode no` is
set because in a pod it protects nothing, so what reaches the port is whatever
Kubernetes routed there. Restrict ingress on `6379`, `16379` and `26379` to the
namespaces that should have it.

### Cluster mode

```yaml
mode: cluster
replicaCount: 6
cluster:
  replicas: 1        # never 0 in production: losing a pod loses its slots

config:
  overrides:
    # 15s is the shipped default and rarely worth lowering. A node that is
    # merely slow — an AOF rewrite, a noisy neighbour, a CNI hiccup during a
    # rolling update — must not be voted out: the failover costs more than the
    # pause that triggered it.
    cluster-node-timeout: 15000

    # Keep serving the slots that are still covered. `yes` takes the whole
    # cluster down as soon as one slot has no owner, which on Kubernetes means
    # a rolling update of one shard stops the other shards too.
    cluster-require-full-coverage: false

# Two members of one shard on one node share its failure.
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: redis
            app.kubernetes.io/instance: redis
```

### Sentinel mode

```yaml
mode: sentinel
replicaCount: 3      # or 5; odd, so a majority survives losing one

sentinel:
  masterSet: mymaster
  quorum: ""         # empty: a strict majority, the only safe value

config:
  overrides:
    # Sentinel promotes on a majority of SENTINELS, not on a majority of data.
    # A master partitioned from them keeps accepting writes until it is demoted,
    # and those writes are then discarded. These two lines are the only defence
    # Redis offers — at the cost of turning a replica outage into a write
    # outage. Set them when a lost acknowledged write costs more than a
    # refused one.
    min-replicas-to-write: 1
    min-replicas-max-lag: 10

readinessProbe:
  # Off unless a stale read is worse than no read at all
  requireMasterLink: false
```

### Node-level settings the chart cannot set

Redis warns about these at startup and they are properties of the **node**, not
of the pod — no `securityContext` reaches them. Apply them with a privileged
DaemonSet, a `kubelet` config, or a machine image:

| Setting | Why |
|---|---|
| `vm.overcommit_memory = 1` | a background save forks; without it the fork can fail under memory pressure and the save silently stops happening |
| Transparent Huge Pages disabled | THP causes latency spikes and much larger copy-on-write during a save |
| `net.core.somaxconn ≥ 511` | namespaced, so this one can go in `podSecurityContext.sysctls` as an unsafe sysctl if the kubelet allows it |

---

## Availability

- **PodDisruptionBudget**, on by default at `maxUnavailable: 1`. Voluntary
  disruptions only — a drain, an upgrade, a descheduler. Both modes tolerate
  losing one pod; losing two of the wrong ones loses a shard in cluster mode and
  can cost the quorum in sentinel mode.
- **Anti-affinity**, applied automatically as a *preference*, so a cluster with
  fewer nodes than pods still schedules. Make it a requirement once you have the
  nodes — see above.
- **`podManagementPolicy: Parallel`**, and not by preference. Every pod waits for
  its peers, so `OrderedReady` — which waits for pod 0 to be ready before
  creating pod 1 — deadlocks the install.
- **`publishNotReadyAddresses: true`** on the headless service, for the same
  reason: the names have to resolve before the pods are ready, or nothing ever
  becomes ready.
- **Rolling updates** trigger a failover per pod in sentinel mode and are handled
  by the chart's startup logic; the set ends with exactly one master.

---

## Values

Only the values worth a summary. `values.yaml` documents every one of them,
with the reasoning.

### Topology

| Key | Default | Description |
|---|---|---|
| `mode` | `cluster` | `cluster` or `sentinel` |
| `replicaCount` | `6` | Pods, and therefore Redis instances |
| `image.repository` | `redis` | [hub.docker.com/_/redis](https://hub.docker.com/_/redis) |
| `image.tag` | `""` | Defaults to the chart `appVersion` (`8.2.8`) |
| `nameOverride` / `fullnameOverride` | `redis` | Objects are named `redis`, `redis-headless`, … |
| `clusterDomain` | `cluster.local` | Must match what the kubelet resolves |

### Cluster mode

| Key | Default | Description |
|---|---|---|
| `cluster.replicas` | `1` | Replicas per master |
| `cluster.init.enabled` | `true` | Run the bootstrap job |
| `cluster.init.waitTimeoutSeconds` | `600` | How long it waits for the pods |

### Sentinel mode

| Key | Default | Description |
|---|---|---|
| `sentinel.masterSet` | `mymaster` | The name clients ask for |
| `sentinel.port` | `26379` | |
| `sentinel.quorum` | `""` | Empty: a strict majority |
| `sentinel.service.type` | `ClusterIP` | Where sentinel-aware clients connect |

### Configuration and files

| Key | Default | Description |
|---|---|---|
| `config.file` | `files/redis.conf` | Base configuration, in the chart |
| `config.modeFile` | `""` | Defaults per mode; `-` for none |
| `config.sentinelFile` | `files/sentinel.conf` | Sentinel's own configuration |
| `config.overrides` | `{}` | Directives, as a map |
| `config.extraConfig` | `""` | Raw text, for repeated directives |
| `config.content` | `""` | Replaces layers 1–2; for `--set-file` |
| `config.sentinelContent` | `""` | Same, for sentinel's own configuration |
| `config.existingConfigMap` | `""` | Replaces layers 1–3 |
| `extraFiles.mountPath` | `/etc/redis/files` | |
| `extraFiles.configMap` / `.secret` | `{}` | Files to inject, `tpl`-rendered |

### Security, storage, backup

| Key | Default | Description |
|---|---|---|
| `auth.enabled` | `false` | Turn it on |
| `auth.existingSecret` | `""` | Bring your own |
| `persistence.enabled` | `true` | |
| `persistence.size` | `8Gi` | Required when enabled |
| `backup.enabled` | `false` | The CronJob |
| `backup.target` | `all` | `all`, `master` or `replica` |
| `backup.retentionDays` | `7` | `0` keeps everything |
| `podSecurityContext` | uid/gid/fsGroup `999` | The image's `redis` user |
| `securityContext.readOnlyRootFilesystem` | `true` | |

### Probes

| Key | Default | Description |
|---|---|---|
| `livenessProbe.checkClusterState` | `true` | cluster mode |
| `readinessProbe.checkClusterState` | `true` | cluster mode |
| `readinessProbe.requireMasterLink` | `false` | sentinel mode |
| `*.command` | `[]` | Replace the script |

---

## Verifying an install

```bash
helm test redis -n redis --logs
```

The test pod checks the **shape** of what was built, which pod readiness cannot.
Instances that never formed a cluster are perfectly healthy instances: they
start, they answer `PING`, they pass every probe. So are replicas that never
found a master. In both cases every pod is `Ready`, the install reports success,
and what you have is not what you asked for.

Cluster mode, on every node — a node can report `ok` while disagreeing with its
peers about who exists. The address check inspects a real `MOVED` redirect, and
not `CLUSTER NODES`, which would pass either way: the announced hostname is
listed there as metadata even when what clients actually receive is a pod IP.

```
==> cluster state, node by node
  ok    redis-0…: state=ok slots=16384 nodes=6 size=3
  …
==> the addresses handed to clients
  ok    redirects carry DNS names (redis-1.redis-headless.redis.svc.cluster.local:6379)
==> write and read back, through the redirects
  ok    wrote and read helm-test-1785977801
```

Sentinel mode — every sentinel must agree *and* see the others, since a quorum
only half of them belong to fails silently until the day a failover is needed.
Sentinels find each other through a hello message rather than at startup, which
takes tens of seconds, so the test polls until the set settles before judging it:

```
==> sentinel
  ok    master is redis-0…:6379
  ok    announced as a DNS name
  ok    all 3 sentinels agree and see each other
==> replication
  ok    2 replica(s) connected
==> write to the master, read from a replica
  ok    replicated to redis-1…
```

The test pod is left behind and replaced on the next run, so `--logs` always has
something to read.

By hand:

```bash
# cluster
kubectl exec -n redis redis-0 -c redis -- redis-cli cluster info
kubectl exec -n redis redis-0 -c redis -- redis-cli cluster nodes

# sentinel
kubectl exec -n redis redis-0 -c sentinel -- \
  redis-cli -p 26379 sentinel master mymaster
```

---

## CI scenarios

`ci/*-values.yaml` is installed and tested by `chart-testing` on every change.
Each was run against a real cluster while the chart was being written.

| Scenario | Covers |
|---|---|
| `scenario-cluster` | 3 masters, no replicas — the smallest cluster that is one |
| `scenario-cluster-replicas` | 3 masters + 3 replicas **with authentication** — the only scenario putting a password in front of `redis-cli --cluster create` |
| `scenario-sentinel` | 1 master, 2 replicas, 3 sentinels |
| `scenario-auth` | sentinel + password + an ACL file + a file from a Secret |
| `scenario-ephemeral` | cluster with no volume at all, the cache shape, **and a configuration supplied whole through `config.content`** |

They use `storageClassName: standard`, which kind provisions out of the box.

---

## Known limitations

- **Switching `mode` on an existing release does not migrate anything.** Install
  a new release and move the data.
- **Growing a cluster is not automatic.** The bootstrap job creates a cluster; it
  does not reshard one. See [Scaling](#scaling).
- **Two releases of this chart cannot share a namespace**, because
  `fullnameOverride` is set to `redis`. Give the second one a
  `fullnameOverride` of its own, or its own namespace.
- **Sentinel has no password of its own.** The Redis instances do; the sentinel
  port is unauthenticated. Restrict it with a NetworkPolicy.
- **TLS is possible but not wired up.** Mount the material through
  `extraFiles.secret` and set `tls-port`, `tls-cert-file` and friends in
  `config.overrides` — the chart's probes and scripts speak plaintext on the
  configured port and would need the same treatment.
- **Helm 4.2.x is slow with this chart, and with any chart that has hooks.** Its
  `--wait` implementation spends the full `--timeout` in each "waiting for
  resources to be deleted" phase, twice per install, whether or not there is
  anything to delete. The release still ends up `deployed` and correct — an
  install measured at 27 seconds under Helm 3.19 took over 12 minutes under Helm
  4.2.1 with `--timeout 6m`. Lower `--timeout`, or use Helm 3, until it is fixed
  upstream.
