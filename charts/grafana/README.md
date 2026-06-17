# Grafana Helm Chart

Helm chart for deploying [Grafana](https://grafana.com/grafana/) on Kubernetes (>= 1.3x).

## Prerequisites

- Kubernetes >= 1.3x
- Helm >= 3.x

## Installation

```bash
helm install grafana ./charts/grafana
```

## Configuration

All parameters are defined in `values.yaml`. Key sections:

| Section | Description |
|---|---|
| `image` | Grafana container image and pull policy |
| `service` | Kubernetes Service type and port |
| `secret` | Sensitive env vars (admin credentials, datasource passwords) — stored as a Secret |
| `configmap` | Non-sensitive env vars (server URL, plugins, feature toggles) — stored as a ConfigMap |
| `persistence` | PersistentVolumeClaim for durable Grafana data storage |
| `ingress` | Optional Ingress to expose Grafana externally |
| `httpRoute` | Optional Gateway API HTTPRoute (alternative to Ingress) |
| `autoscaling` | Horizontal Pod Autoscaler settings |
| `resources` | CPU/memory requests and limits |

### Enabling persistence

```yaml
persistence:
  enabled: true
  storageClassName: "standard"
  accessModes:
    - ReadWriteOnce
  size: 10Gi

volumes:
  - name: grafana-storage
    persistentVolumeClaim:
      claimName: grafana

volumeMounts:
  - name: grafana-storage
    mountPath: "/var/lib/grafana"
    readOnly: false
```

### Admin credentials example

```yaml
secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: strongpassword
```

## Uninstallation

```bash
helm uninstall grafana
```

> The PVC is **not** deleted automatically on uninstall. Delete it manually if no longer needed:
> `kubectl delete pvc grafana`
