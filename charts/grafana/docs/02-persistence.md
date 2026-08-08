# Durable storage — keeping dashboards across restarts

Grafana keeps its dashboards, users, plugins and API keys in `/var/lib/grafana`. Without a volume
there, every pod restart starts from an empty instance. This scenario creates the PVC **and** mounts
it — two separate steps in this chart.

## Values

```yaml
# values-persistence.yaml
replicaCount: 1        # ReadWriteOnce binds to one node: do not scale this up

image:
  repository: grafana/grafana
  tag: "11.6.1"

secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: change-me-please

configmap:
  GF_SERVER_ROOT_URL: "http://localhost:3000"
  # Plugins are installed into /var/lib/grafana/plugins at startup, so they are
  # downloaded once and then survive on the volume.
  GF_INSTALL_PLUGINS: "grafana-clock-panel,yesoreyeram-infinity-datasource"

# Step 1 — create the claim.
persistence:
  enabled: true
  storageClassName: ""       # "" takes the cluster default StorageClass
  accessModes:
    - ReadWriteOnce
  size: 10Gi

# Step 2 — mount it. claimName is the chart fullname, "grafana" with the
# default fullnameOverride.
volumes:
  - name: grafana-storage
    persistentVolumeClaim:
      claimName: grafana

volumeMounts:
  - name: grafana-storage
    mountPath: /var/lib/grafana
    readOnly: false

# The image runs as uid/gid 472. fsGroup makes the volume group-writable for it;
# without it, a freshly provisioned volume is owned by root and Grafana fails to
# open its database.
podSecurityContext:
  fsGroup: 472

readinessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 10

resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## Install

```bash
helm install grafana oci://ghcr.io/willbrid/charts/grafana \
  --version 0.1.1 \
  --namespace monitoring --create-namespace \
  --values values-persistence.yaml
```

## Verify it really persists

```bash
kubectl -n monitoring get pvc grafana        # STATUS must be Bound
# create a dashboard in the UI, then:
kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana
kubectl -n monitoring rollout status deployment/grafana
# the dashboard is still there
```

## What to know

- **Enabling `persistence` alone does nothing visible.** It creates the claim; the `volumes` /
  `volumeMounts` pair is what puts it in front of `/var/lib/grafana`. Forgetting the second half
  gives you a Bound PVC that nothing writes to.
- **The claim outlives the release.** `helm uninstall` leaves it behind on purpose, so a re-install
  picks the data back up. Delete it explicitly when you are done:
  `kubectl -n monitoring delete pvc grafana`.
- **`ReadWriteOnce` and more than one replica do not mix.** Two pods on two nodes cannot both attach
  the volume, and two Grafana processes on one SQLite file corrupt it. For several replicas, see
  [High availability](05-ha-external-database.md).
- Resizing later means editing the PVC, not the values: `persistence.size` is only read at creation.
  The StorageClass must have `allowVolumeExpansion: true`.
