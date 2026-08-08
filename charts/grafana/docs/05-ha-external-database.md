# High availability — several replicas on a shared PostgreSQL

Two or more Grafana pods behind one service, all reading and writing the same external database.
This is the only supported way to run more than one replica: SQLite on a shared volume corrupts, and
SQLite on separate volumes gives each pod its own disjoint set of dashboards and users.

Requires a PostgreSQL (or MySQL) reachable from the cluster, with a database and a role already
created.

## Values

```yaml
# values-ha.yaml
replicaCount: 2

image:
  repository: grafana/grafana
  tag: "11.6.1"

secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: change-me-please
  GF_DATABASE_PASSWORD: change-me-too

configmap:
  GF_SERVER_ROOT_URL: "https://grafana.example.com"
  GF_SECURITY_COOKIE_SECURE: "true"
  GF_USERS_ALLOW_SIGN_UP: "false"
  # Shared state. Every replica reads its dashboards, users and API keys here,
  # which is what makes them interchangeable behind the service.
  GF_DATABASE_TYPE: "postgres"
  GF_DATABASE_HOST: "postgres.databases.svc.cluster.local:5432"
  GF_DATABASE_NAME: "grafana"
  GF_DATABASE_USER: "grafana"
  GF_DATABASE_SSL_MODE: "require"
  # Alert evaluation and silences are stored in the same database; unified
  # alerting is what lets several replicas share the scheduling.
  GF_UNIFIED_ALERTING_ENABLED: "true"
  # Sessions live in the database too, so a request landing on any pod stays
  # signed in — no session affinity needed on the Ingress.
  GF_SESSION_PROVIDER: "postgres"

# No PVC: nothing worth keeping is on local disk any more. Plugins are
# re-downloaded into the container at startup.
persistence:
  enabled: false

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: grafana.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: grafana-tls
      hosts:
        - grafana.example.com

# Spread the replicas: two pods on one node survive nothing a single pod would
# not have survived.
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          topologyKey: kubernetes.io/hostname
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: grafana

readinessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 10
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 30
  failureThreshold: 6

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: "1"
    memory: 1Gi

# Optional: let the HPA drive the count instead of replicaCount. Grafana is
# rarely CPU-bound — enable this for bursty dashboard loads, not by default.
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 80
```

## Install

```bash
helm install grafana oci://ghcr.io/willbrid/charts/grafana \
  --version 0.1.1 \
  --namespace monitoring --create-namespace \
  --values values-ha.yaml
```

## Verify both replicas share one state

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana -o wide
# database reachable, per pod
kubectl -n monitoring logs -l app.kubernetes.io/name=grafana --tail=20 | grep -i "migrat\|database"
# create a dashboard, then delete the pod that served you: it is still there
```

## What to know

- **`autoscaling.enabled: true` makes the chart drop `replicas` from the Deployment**, handing the
  count to the HPA. Setting both is harmless but `replicaCount` is then ignored.
- **The first pod to start runs the schema migrations.** On a fresh database, roll out one replica
  first, or accept that the others restart once while the migration holds its lock.
- **Plugins are per-pod without a volume.** `GF_INSTALL_PLUGINS` downloads them at every pod start —
  fine, but it means each pod needs egress to grafana.com, and a slow download delays readiness.
  Baking the plugins into your own image avoids both.
- **Provision dashboards as code** here rather than clicking them in: with several interchangeable
  replicas, a dashboard that exists only because someone saved it in the UI is state you cannot
  rebuild.
