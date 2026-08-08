# Hardened — restricted Pod Security Standard

Grafana running as a non-root user with no capabilities and a read-only root filesystem, which is
what a namespace labelled `pod-security.kubernetes.io/enforce: restricted` requires. The chart sets
no security context by default, so a pod created from the default values is **rejected** in such a
namespace.

## Values

```yaml
# values-hardened.yaml
replicaCount: 1

image:
  repository: grafana/grafana
  tag: "11.6.1"

secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: change-me-please

configmap:
  GF_SERVER_ROOT_URL: "http://localhost:3000"
  GF_USERS_ALLOW_SIGN_UP: "false"
  # Plugin installation writes to /var/lib/grafana, which is a volume below —
  # it would fail against a read-only root filesystem otherwise.
  GF_PATHS_PLUGINS: "/var/lib/grafana/plugins"

# 472 is the uid/gid the official image ships. fsGroup is what makes a freshly
# provisioned volume writable for it.
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 472
  runAsGroup: 472
  fsGroup: 472
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL

persistence:
  enabled: true
  size: 10Gi

# With a read-only root filesystem, every directory Grafana writes to must be a
# volume. /var/lib/grafana is the data, /tmp is scratch space used by the
# rendering and provisioning code paths.
volumes:
  - name: grafana-storage
    persistentVolumeClaim:
      claimName: grafana
  - name: tmp
    emptyDir: {}

volumeMounts:
  - name: grafana-storage
    mountPath: /var/lib/grafana
  - name: tmp
    mountPath: /tmp

# No API access is needed by Grafana itself; not mounting the token removes a
# credential from the container.
serviceAccount:
  create: true
  automount: false

readinessProbe:
  httpGet:
    path: /api/health
    port: http
  initialDelaySeconds: 10

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: "1"
    memory: 1Gi
```

## Install

```bash
kubectl create namespace monitoring
kubectl label namespace monitoring \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

helm install grafana oci://ghcr.io/willbrid/charts/grafana \
  --version 0.1.1 \
  --namespace monitoring \
  --values values-hardened.yaml
```

If the namespace label is what you are testing, install first with `--dry-run=server`: the admission
webhook rejects a non-conforming pod at that point, before any object is created.

## Verify

```bash
kubectl -n monitoring get pod -l app.kubernetes.io/name=grafana \
  -o jsonpath='{.items[0].spec.containers[0].securityContext}{"\n"}'
# writing outside the mounted volumes must fail
kubectl -n monitoring exec deploy/grafana -- sh -c 'touch /etc/probe' || echo "read-only root: expected"
```

## What to know

- **`readOnlyRootFilesystem` is the setting that breaks things**, not the uid. Anything Grafana
  writes outside `/var/lib/grafana` and `/tmp` needs its own `emptyDir`; the symptom is a crash loop
  with a permission error naming the exact path, so add the mount it asks for.
- **`restricted` also forbids `allowPrivilegeEscalation: true`, any added capability and a missing
  `seccompProfile`.** All four are set above; drop one and admission refuses the pod.
- **A custom image with a different uid needs all three numbers changed** (`runAsUser`,
  `runAsGroup`, `fsGroup`), otherwise the volume stays unwritable.
- This composes with the other scenarios: add the `ingress` block from
  [Ingress with TLS](03-ingress-tls.md) as-is, none of it conflicts.
