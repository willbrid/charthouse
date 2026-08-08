# Quick start — a single Grafana, reachable through port-forward

The smallest install worth running: one replica, own admin credentials, real probes and a resource
budget. Nothing is exposed outside the cluster, so it is also the safest way to try the chart on a
cluster you do not own.

## Values

```yaml
# values-quickstart.yaml
replicaCount: 1

image:
  repository: grafana/grafana
  tag: "11.6.1"          # pin it: "latest" silently upgrades Grafana on every pod restart
  pullPolicy: IfNotPresent

# Credentials, base64-encoded into the Secret <fullname>.
secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: change-me-please

# Everything non-confidential, plain text in the ConfigMap <fullname>.
configmap:
  GF_SERVER_ROOT_URL: "http://localhost:3000"
  GF_LOG_LEVEL: "info"
  GF_USERS_ALLOW_SIGN_UP: "false"

service:
  type: ClusterIP
  port: 3000
  portname: http

# /api/health is the endpoint Grafana itself considers authoritative: it reports
# the database state, not just an open socket.
readinessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 10
  periodSeconds: 10
livenessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 6

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
  --values values-quickstart.yaml
```

## Verify

```bash
kubectl -n monitoring rollout status deployment/grafana
kubectl -n monitoring port-forward svc/grafana 3000:3000
# then open http://localhost:3000 and sign in with the credentials above
```

## What to know

- **No persistence here.** Dashboards, users and the SQLite database live in the container
  filesystem and disappear with the pod. Move on to [Durable storage](02-persistence.md) before
  putting anything you care about in it.
- **`GF_SERVER_ROOT_URL` must match the URL you actually browse.** Grafana builds its redirects and
  asset links from it; leave it on `localhost:3000` only as long as you reach it by port-forward.
- The admin password sits in plain text in this file and in the release. For anything shared, keep
  the Secret out of the chart and let an external secret manager produce it.
