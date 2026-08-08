# Scheduled backups, shipped to object storage

A CronJob that asks each Redis instance for a fresh RDB, writes it to a volume, and then pushes it
off the cluster. Off by default in the chart, because where a backup belongs is a decision only you
can make.

**What this protects against:** a bad `FLUSHALL`, a corrupted dataset, an accidental
`helm uninstall` followed by a PVC deletion, a namespace deleted by mistake.
**What it does not:** losing the last few minutes of writes. A dump is a point in time.

## The destination volume

The chart's default is an `emptyDir`, which loses the backup with the pod — a placeholder, not a
backup. Give it a real PVC:

```yaml
# backup-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-backups
  namespace: redis
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: standard
  resources:
    requests:
      storage: 100Gi
```

## Values

```yaml
# values-backup.yaml
mode: cluster
replicaCount: 6

image:
  repository: redis
  tag: "8.2.8"

cluster:
  replicas: 1

auth:
  enabled: true
  password: ""

config:
  overrides:
    maxmemory: 2gb
    maxmemory-policy: noeviction

persistence:
  enabled: true
  size: 20Gi

backup:
  enabled: true

  # 03:00 daily. Pick a window when the write rate is low: BGSAVE forks, and the
  # fork's copy-on-write pages cost real memory in proportion to what changes
  # during the dump.
  schedule: "0 3 * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  activeDeadlineSeconds: 3600
  backoffLimit: 2
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3

  # In cluster mode each master holds a different share of the keyspace, so
  # "all" is the only correct answer — a dump of one node is a sixth of the
  # data. In sentinel mode, "replica" keeps the fork off the instance serving
  # writes.
  target: all

  # Local copies pruned after a week; the real retention lives in the bucket's
  # lifecycle policy.
  retentionDays: 7

  storage:
    persistentVolumeClaim:
      claimName: redis-backups
  mountPath: /backup

  # Runs after each dump, in the same container, with BACKUP_DIR and BACKUP_FILE
  # set. The redis image has no aws CLI — see the note below.
  postBackupScript: |
    set -eu
    echo "shipping ${BACKUP_FILE} to object storage"
    aws s3 cp "$BACKUP_FILE" "s3://my-bucket/redis/$(date +%Y/%m/%d)/" --only-show-errors

  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi

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
kubectl apply -f backup-pvc.yaml

helm install redis oci://ghcr.io/willbrid/charts/redis \
  --version 0.1.0 \
  --namespace redis --create-namespace \
  --values values-backup.yaml
```

## Verify before you need it

```bash
kubectl -n redis get cronjob redis-backup

# do not wait for 03:00
kubectl -n redis create job redis-backup-manual --from=cronjob/redis-backup
kubectl -n redis logs job/redis-backup-manual -f

# what landed on the volume
kubectl -n redis run backup-browser --rm -it --restart=Never \
  --image=busybox --overrides='{"spec":{"containers":[{"name":"b","image":"busybox",
  "command":["sh"],"stdin":true,"tty":true,
  "volumeMounts":[{"name":"b","mountPath":"/backup"}]}],
  "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"redis-backups"}}]}}' \
  -- sh -c 'ls -lh /backup'
```

**Restore-test it at least once.** A backup nobody has restored is a hypothesis. The chart README's
*Restoring* section has the full procedure; the shape of it is:

```bash
# 1. stop the writers, scale the release down
kubectl -n redis scale statefulset/redis --replicas=0

# 2. put the dump on pod 0's PVC, named as `dbfilename` says (dump.rdb)
#    — a scratch pod mounting data-redis-0 is the simplest way

# 3. AOF wins over RDB at load time: remove appendonlydir if appendonly is on,
#    or the RDB you just restored is ignored

# 4. bring pod 0 back first, let it become master, then the rest
kubectl -n redis scale statefulset/redis --replicas=6
```

## What to know

- **The `redis` image has no `aws`, `gcloud` or `az` CLI.** The `postBackupScript` above needs one:
  either build an image with the client and set `image.repository` for the whole release (heavy), or
  leave `postBackupScript` empty and run a separate CronJob that syncs the PVC to your bucket. The
  second is usually the cleaner split.
- **A dump on a PVC in the same cluster is not off-site.** It survives a deleted namespace; it does
  not survive the cluster or the storage backend. The `postBackupScript` is the step that makes this
  a real backup.
- **`BGSAVE` forks the process.** The child shares the parent's memory copy-on-write, so peak usage
  grows with how much changes while the dump runs. On a write-heavy instance, budget for it or
  target the replicas.
- **Restoring a cluster is not restoring an instance.** Each master's dump belongs to the ordinal it
  came from, and the restored cluster must have the same `replicaCount` and `cluster.replicas` as
  the one the dumps came from. Restore per node, then let the cluster form with
  `cluster.init.enabled: true`.
- **`concurrencyPolicy: Forbid` is deliberate.** Two dumps at once on one instance is load you did
  not ask for, and two writers on one volume is worse.
