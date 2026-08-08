# Public exposure — Gateway API HTTPRoute

The same exposure as [Ingress with TLS](03-ingress-tls.md), routed through the Gateway API instead.
Pick this one when the cluster already standardises on Gateways: TLS, the listener and the hostname
live on the Gateway, and the chart only attaches a route to it.

Requires the Gateway API CRDs (`gateway.networking.k8s.io/v1`) and a controller implementing them
(Envoy Gateway, Istio, Contour, nginx-gateway-fabric, Cilium…), plus an existing Gateway.

## The Gateway this route attaches to

Not created by the chart — it usually belongs to the platform team and is shared:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: public-gateway
  namespace: gateway-system
spec:
  gatewayClassName: envoy
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      hostname: "*.example.com"
      tls:
        mode: Terminate
        certificateRefs:
          - name: wildcard-example-tls
      allowedRoutes:
        namespaces:
          from: Selector
          selector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
```

## Values

```yaml
# values-httproute.yaml
replicaCount: 1

image:
  repository: grafana/grafana
  tag: "11.6.1"

secret:
  GF_SECURITY_ADMIN_USER: admin
  GF_SECURITY_ADMIN_PASSWORD: change-me-please

configmap:
  GF_SERVER_ROOT_URL: "https://grafana.example.com"
  GF_SECURITY_COOKIE_SECURE: "true"
  GF_USERS_ALLOW_SIGN_UP: "false"

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

# Ingress stays off: one route to the service is enough.
ingress:
  enabled: false

httpRoute:
  enabled: true
  parentRefs:
    - name: public-gateway
      namespace: gateway-system
      sectionName: https        # the listener declared above
  hostnames:
    - grafana.example.com
  rules:
    # Everything under / goes to Grafana. The chart fills in the backendRef
    # itself: the release service, on service.port.
    - matches:
        - path:
            type: PathPrefix
            value: /

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
  --values values-httproute.yaml
```

## Verify

```bash
kubectl -n monitoring get httproute grafana
# Accepted=True and ResolvedRefs=True is what says the Gateway took the route
kubectl -n monitoring get httproute grafana -o jsonpath='{.status.parents[*].conditions[*].type}{"\n"}'
curl -sI https://grafana.example.com/api/health
```

## What to know

- **A route across namespaces needs the Gateway's permission.** `allowedRoutes` on the listener is
  what grants it; a route the Gateway refuses shows `Accepted=False` and no traffic — with no error
  anywhere in the Helm release.
- **The chart derives the `backendRefs` itself** (release service, `service.port`, weight 1), so a
  rule only carries its `matches` and optional `filters`.
- **TLS is the Gateway's business here**, not the chart's: there is no `tls` block in `httpRoute`.
  That is the main practical difference with the Ingress version.
