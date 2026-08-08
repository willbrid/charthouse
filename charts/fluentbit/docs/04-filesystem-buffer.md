# Filesystem buffer on a StatefulSet — surviving a backend outage

An aggregator whose in-flight records are written to disk rather than held in memory, on a volume
that stays with the pod across restarts. This is the configuration that keeps logs when
Elasticsearch is down for twenty minutes, and the reason to pick `kind: StatefulSet` over a
Deployment.

## Values

```yaml
# values-buffer.yaml
# StatefulSet is what gives each pod a stable identity, and volumeClaimTemplates
# only work with it — the chart fails the render otherwise rather than dropping
# storage that was asked for.
kind: StatefulSet
replicaCount: 3

statefulSet:
  # Aggregator replicas have no ordering constraint between them, so let them
  # start at once instead of one after another.
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate

image:
  repository: fluent/fluent-bit
  tag: "5.0.9"

command:
  - "/fluent-bit/bin/fluent-bit"

configMountPath: /fluent-bit/etc
configFileName: fluent-bit.conf

# One PVC per pod, named buffer-fluentbit-0, buffer-fluentbit-1, …
# Each stays bound to its ordinal: pod 1 restarting gets its own chunks back,
# not another pod's.
volumeClaimTemplates:
  - name: buffer
    size: 10Gi
    accessModes:
      - ReadWriteOnce
    storageClassName: ""       # "" takes the cluster default StorageClass

# Declaring the claim does not mount it. This is the other half.
volumeMounts:
  - name: buffer
    mountPath: /var/log/flb-storage

secret:
  ES_PASSWORD: "changeme"

configmap:
  ES_HOST: "elasticsearch.logging.svc.cluster.local"

service:
  type: ClusterIP
  ports:
    - name: health
      port: 2020
      targetPort: 2020
      protocol: TCP
    - name: forward
      port: 24224
      targetPort: 24224
      protocol: TCP

config: |
  [SERVICE]
      daemon        Off
      flush         1
      log_level     info
      http_server   On
      http_listen   0.0.0.0
      http_port     2020
      health_check  On
      # The directory Fluent Bit writes its chunks to — the PVC mounted above.
      # It refuses to start when this is not writable, which is the failure you
      # want loud rather than silent.
      storage.path              /var/log/flb-storage/
      storage.sync              normal
      # Skip chunks whose checksum does not match after a crash instead of
      # aborting startup.
      storage.checksum          Off
      # Total memory the queued-up chunks may occupy before inputs are paused.
      storage.max_chunks_up     128
      # Backlog restored on startup, capped so a long outage does not blow up
      # the pod the moment it comes back.
      storage.backlog.mem_limit 64M
      # Exposes storage_* counters on /api/v1/storage.
      storage.metrics           On

  [INPUT]
      name              forward
      listen            0.0.0.0
      port              24224
      # The line that actually moves this input to disk. Without it, the
      # storage.path above is set up and unused.
      storage.type      filesystem
      mem_buf_limit     10MB

  [OUTPUT]
      name              es
      match             *
      host              ${ES_HOST}
      port              9200
      http_user         fluentbit
      http_passwd       ${ES_PASSWORD}
      index             applogs
      suppress_type_name On
      # How much of the backlog this output may hold before applying back
      # pressure to the input.
      storage.total_limit_size  5G
      retry_limit       False

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: "1"
    memory: 1Gi
```

## Install

```bash
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging --create-namespace \
  --values values-buffer.yaml
```

## Verify the buffer is real

```bash
kubectl -n logging get pvc -l app.kubernetes.io/name=fluentbit
# buffer-fluentbit-0/1/2, all Bound

kubectl -n logging exec fluentbit-0 -- ls -la /var/log/flb-storage/

# chunk counters, memory vs filesystem
kubectl -n logging port-forward svc/fluentbit 2020:2020 &
curl -s localhost:2020/api/v1/storage | jq .

# the real test: break the output, send records, watch chunks land on disk
kubectl -n logging scale statefulset/elasticsearch --replicas=0   # or block it
# … send logs …
kubectl -n logging exec fluentbit-0 -- du -sh /var/log/flb-storage/
```

## What to know

- **`storage.path` alone buffers nothing.** Each input needs `storage.type filesystem`; inputs left
  on the default `memory` keep losing their queue on restart even with the volume mounted.
- **`retry_limit False` means retry forever**, which is what you want with a durable buffer —
  paired with `storage.total_limit_size` so the disk cannot fill without bound. Once that limit is
  reached, the oldest chunks are dropped, not the newest.
- **The PVCs outlive the release.** `helm uninstall` leaves `buffer-fluentbit-*` behind so a
  re-install picks the pending chunks back up. Delete them explicitly when you are done:
  `kubectl -n logging delete pvc -l app.kubernetes.io/name=fluentbit`.
- **Scaling down does not delete the PVC of the removed pod**, and scaling back up reattaches it.
  That is the behaviour you want here; it also means a shrunk StatefulSet leaves chunks nobody is
  flushing until you scale back up.
- **`ReadWriteOnce` is right here.** Each pod owns its own claim — this is not shared storage, and
  `volumeClaimTemplates` is precisely what distinguishes it from the shared `volumes` section.
- **Autoscaling and a fixed `replicaCount` fight each other.** Leave `autoscaling.enabled: false`
  with a buffer: an HPA scaling in strands the chunks of the pod it removed.
