# Public exposure — Ingress with TLS

Grafana behind an Ingress controller on a real hostname, with a certificate issued by cert-manager.
Builds on [Durable storage](02-persistence.md): a Grafana people log into is one whose data you want
to keep.

Requires an Ingress controller (nginx here) and, for the certificate, cert-manager with a
ClusterIssuer. Without cert-manager, drop the annotation and create the `grafana-tls` Secret
yourself.

## Values

```yaml
# values-ingress.yaml
replicaCount: 1

image:
  repository: grafana/grafana
  tag: "11.6.1"

secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: change-me-please

configmap:
  # Must be the public URL, scheme included. Grafana builds every redirect,
  # asset link and OAuth callback from it — a wrong value gives you a login
  # page that redirects to the wrong host.
  GF_SERVER_ROOT_URL: "https://grafana.example.com"
  GF_SERVER_ENFORCE_DOMAIN: "true"
  GF_USERS_ALLOW_SIGN_UP: "false"
  # Cookies marked Secure only travel over HTTPS, which is what the Ingress
  # terminates here.
  GF_SECURITY_COOKIE_SECURE: "true"

persistence:
  enabled: true
  size: 10Gi

volumes:
  - name: grafana-storage
    persistentVolumeClaim:
      claimName: grafana

volumeMounts:
  - name: grafana-storage
    mountPath: /var/lib/grafana

podSecurityContext:
  fsGroup: 472

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
  hosts:
    - host: grafana.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: grafana-tls
      hosts:
        - grafana.example.com

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
helm install grafana oci://ghcr.io/willbrid/charts/grafana \
  --version 0.1.1 \
  --namespace monitoring --create-namespace \
  --values values-ingress.yaml
```

## Verify

```bash
kubectl -n monitoring get ingress grafana
kubectl -n monitoring get secret grafana-tls        # created by cert-manager
curl -sI https://grafana.example.com/api/health     # expect 200
```

## What to know

- **`ingress` and `httpRoute` are alternatives.** Enabling both publishes the same service twice
  through two data paths; pick one. The Gateway API route is in
  [Gateway API](04-gateway-api.md).
- **Serving Grafana under a sub-path** (`https://example.com/grafana`) needs the path rewritten by
  the controller *and* `GF_SERVER_SERVE_FROM_SUB_PATH: "true"` with the sub-path included in
  `GF_SERVER_ROOT_URL`. Setting only one of the two produces broken asset URLs.
- **Anonymous access**, for a dashboard on a wall screen, is `GF_AUTH_ANONYMOUS_ENABLED: "true"` and
  `GF_AUTH_ANONYMOUS_ORG_ROLE: "Viewer"` in `configmap` — do not put it on a public hostname
  without thinking about who reaches it.
