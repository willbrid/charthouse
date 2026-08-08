# grafana

A Helm chart for installing [Grafana](https://grafana.com/grafana/) (**OSS** edition) in Kubernetes.

| | |
|---|---|
| Chart | `oci://ghcr.io/willbrid/charts/grafana` |
| Source | [charthouse](https://github.com/willbrid/charthouse/tree/main/charts/grafana) |
| Container image | [`grafana/grafana`](https://hub.docker.com/r/grafana/grafana) (Docker Hub) |

---

## Container image

This chart builds and hosts no image. It deploys the official **Grafana OSS** image published on
Docker Hub: **[hub.docker.com/r/grafana/grafana](https://hub.docker.com/r/grafana/grafana)**.

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `grafana/grafana` | Docker Hub repository |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |

`grafana/grafana` **is** the Open Source edition — the Enterprise edition lives in a separate
repository, `grafana/grafana-enterprise`. The historical OSS repository
[`grafana/grafana-oss`](https://hub.docker.com/r/grafana/grafana-oss) holds the very same images,
but Grafana Labs stopped updating it with the 12.4.0 release: use `grafana/grafana` for anything new.

> **Pin a tag.** `latest` is convenient for a first try but is not reproducible: two pods of the same
> release can end up on two different builds, and a Grafana upgrade migrates its database on
> startup. Set `image.tag` to an explicit version for anything beyond a test.

```yaml
image:
  repository: grafana/grafana
  tag: "12.4.0"
  pullPolicy: IfNotPresent
```

`image.repository` also accepts a private mirror of that same image, combined with
`imagePullSecrets` when the registry requires credentials.

---

## Prerequisites

| Requirement | Minimum version |
|-------------|-----------------|
| Kubernetes | `1.30` |
| Helm | `3.8` (OCI support) |

The chart is distributed **only** as an OCI artifact on `ghcr.io` — there is no `helm repo add`
index. A Helm client older than `3.8` cannot pull it at all.

```bash
helm version --short   # must report v3.8.0 or later
```

---

## Install

```bash
# Latest published version, default values
helm install grafana oci://ghcr.io/willbrid/charts/grafana

# Pinned version, own values, dedicated namespace
helm install grafana oci://ghcr.io/willbrid/charts/grafana \
  --version 0.1.1 \
  --namespace monitoring --create-namespace \
  --values my-values.yaml
```

`my-values.yaml` only holds what you override; everything else falls back to
[`values.yaml`](values.yaml).

Inspect before installing:

```bash
helm show values oci://ghcr.io/willbrid/charts/grafana    # all available values
helm template grafana oci://ghcr.io/willbrid/charts/grafana \
  --values my-values.yaml                                 # rendered manifests
helm install grafana oci://ghcr.io/willbrid/charts/grafana \
  --values my-values.yaml --dry-run --debug               # server-side validation
```

Reaching the UI without exposing it yet:

```bash
kubectl port-forward svc/grafana 3000:3000 --namespace monitoring
```

## Upgrade

```bash
helm upgrade grafana oci://ghcr.io/willbrid/charts/grafana \
  --version 0.1.1 \
  --namespace monitoring \
  --values my-values.yaml
```

## Uninstall

```bash
helm uninstall grafana --namespace monitoring
```

> The PVC is **not** deleted with the release — dashboards and the SQLite database survive, so a
> re-install picks them back up. Delete it explicitly when it is no longer wanted:
> `kubectl delete pvc grafana --namespace monitoring`.

---

## Example scenarios

Complete values files, one per installation shape, in [`docs/`](docs/). Each page carries the values,
the install command and how to check the result.

| # | Scenario | What it covers |
|---|---|---|
| 1 | [Quick start](docs/01-quickstart.md) | One replica, own admin credentials, probes and resources — reached by port-forward |
| 2 | [Durable storage](docs/02-persistence.md) | PVC created **and** mounted on `/var/lib/grafana`, `fsGroup` for uid 472 |
| 3 | [Ingress with TLS](docs/03-ingress-tls.md) | Public hostname behind an Ingress controller, certificate from cert-manager |
| 4 | [Gateway API](docs/04-gateway-api.md) | The same exposure as an HTTPRoute attached to a shared Gateway |
| 5 | [High availability](docs/05-ha-external-database.md) | Several replicas on a shared PostgreSQL, anti-affinity, optional HPA |
| 6 | [Hardened](docs/06-hardened.md) | Non-root, no capabilities, read-only root filesystem — passes the `restricted` Pod Security Standard |

---

## Configuration

| Section | Description |
|---|---|
| `image` | Grafana image and pull policy |
| `service` | Service type and port |
| `secret` | Sensitive env vars (admin credentials, datasource passwords) — stored in a Secret |
| `configmap` | Non-sensitive env vars (server URL, plugins, feature toggles) — stored in a ConfigMap |
| `persistence` | PersistentVolumeClaim for durable Grafana data |
| `ingress`, `httpRoute` | Optional external exposure (Ingress or Gateway API) |
| `livenessProbe`, `readinessProbe` | Health checks |
| `replicaCount`, `autoscaling` | Number of pods, fixed or driven by an HPA |
| `volumes`, `volumeMounts` | Extra volumes, and where the PVC gets mounted |
| `resources`, `nodeSelector`, `tolerations`, `affinity` | Scheduling and limits |

### Configuring Grafana

Grafana is configured through `GF_*` environment variables, which this chart splits in two — each
resource being created only when its section is non-empty:

```yaml
secret:                      # base64-encoded, into a Secret
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: strongpassword

configmap:                   # plain text, into a ConfigMap
  GF_SERVER_ROOT_URL: "https://grafana.example.com"
  GF_INSTALL_PLUGINS: "grafana-clock-panel,yesoreyeram-infinity-datasource"
```

Every setting of the [configuration reference](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
has a `GF_<SECTION>_<KEY>` equivalent.

> `secret` values sit in plain text in your values file and in the release. For real credentials,
> prefer an external secret manager and reference the Secret it produces.

### Persistence

Without it, Grafana runs on ephemeral storage and loses its dashboards, plugins and SQLite database
on every restart. Enabling `persistence` creates the PVC; mounting it is a separate step:

```yaml
persistence:
  enabled: true
  storageClassName: "standard"     # "" uses the cluster default StorageClass
  accessModes:
    - ReadWriteOnce
  size: 10Gi

volumes:
  - name: grafana-storage
    persistentVolumeClaim:
      claimName: grafana           # matches the chart fullname

volumeMounts:
  - name: grafana-storage
    mountPath: "/var/lib/grafana"
    readOnly: false
```

`ReadWriteOnce` binds the volume to a single node: keep `replicaCount: 1` and `autoscaling` off with
it, unless the StorageClass supports `ReadWriteMany`.

### External exposure

Either an Ingress, or a Gateway API HTTPRoute — not both:

```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: grafana.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: grafana-tls
      hosts:
        - grafana.example.com
```

Set `GF_SERVER_ROOT_URL` in `configmap` to the public URL at the same time: Grafana builds its
redirects and asset links from it.

The `httpRoute` section covers the Gateway API alternative and requires the Gateway API CRDs plus a
controller in the cluster.

---

## Reference

- All values, documented inline: [`values.yaml`](values.yaml)
- Working configurations covering each feature: [`ci/`](ci/) — one file per scenario, exercised by
  the CI on a real cluster
- Grafana configuration reference: <https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/>
