# TLS on the OTLP receivers

The collector accepting OTLP only over TLS, with the certificate and key coming from a Secret
mounted into the container. Use this when senders are outside the mesh — or outside the cluster, see
[Accepting OTLP from outside](05-ingress-otlp.md) — and nothing else terminates TLS in front.

## The certificate

Whatever produces it, the result is a Secret with the usual two keys. With cert-manager:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: otelcollector-tls
  namespace: observability
spec:
  secretName: otelcollector-tls
  issuerRef:
    name: internal-ca
    kind: ClusterIssuer
  dnsNames:
    - otelcollector.observability.svc.cluster.local
    - otelcollector.observability.svc
```

## Values

```yaml
# values-tls.yaml
replicaCount: 2

image:
  repository: otel/opentelemetry-collector-contrib
  tag: "0.157.0"

command:
  - "/otelcol-contrib"

service:
  type: ClusterIP
  ports:
    - name: otlp-grpc
      port: 4317
      targetPort: 4317
      protocol: TCP
    - name: otlp-http
      port: 4318
      targetPort: 4318
      protocol: TCP
    - name: health
      port: 13133
      targetPort: 13133
      protocol: TCP

# The chart always mounts the configuration ConfigMap as the `config` volume at
# /conf. Extra volumes go here and must not reuse that name.
volumes:
  - name: tls
    secret:
      secretName: otelcollector-tls
      defaultMode: 0400

volumeMounts:
  - name: tls
    mountPath: /etc/otel/tls
    readOnly: true

config: |
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317
          tls:
            cert_file: /etc/otel/tls/tls.crt
            key_file: /etc/otel/tls/tls.key
            min_version: "1.2"
            # Uncomment to require client certificates too (mTLS). The CA must
            # be mounted alongside the certificate.
            # client_ca_file: /etc/otel/tls/ca.crt
        http:
          endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4318
          tls:
            cert_file: /etc/otel/tls/tls.crt
            key_file: /etc/otel/tls/tls.key
            min_version: "1.2"

  processors:
    memory_limiter:
      check_interval: 5s
      limit_percentage: 80
      spike_limit_percentage: 25
    batch: {}

  exporters:
    otlp/tempo:
      endpoint: tempo.observability.svc.cluster.local:4317
      tls:
        insecure: true

  extensions:
    # Left in plain HTTP on purpose: the kubelet running the probes has no
    # reason to trust the internal CA, and this endpoint carries no data.
    health_check:
      endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133

  service:
    extensions: [health_check]
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlp/tempo]

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 1Gi
```

## Install

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability --create-namespace \
  --values values-tls.yaml
```

## Verify

```bash
# the certificate the collector actually presents
kubectl -n observability exec deploy/otelcollector -- \
  openssl s_client -connect localhost:4318 -servername otelcollector.observability.svc.cluster.local </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates

# plaintext must now be refused
kubectl -n observability port-forward svc/otelcollector 4318:4318 &
curl -s http://localhost:4318/v1/traces -d '{}' ; echo "  <- expected to fail"
curl -sk https://localhost:4318/v1/traces -H 'Content-Type: application/json' -d '{}'
```

## What to know

- **Senders must be updated at the same time.** An SDK configured with
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://…` keeps failing silently against a TLS listener; it needs the
  `https://` scheme and, for a private CA, the CA certificate. This is the part that breaks in
  practice, not the collector side.
- **The certificate must match the name senders dial**, which for in-cluster traffic is the service
  DNS name, not the pod IP. Getting `dnsNames` wrong shows up as `x509: certificate is valid for …`
  in the sender's logs.
- **Rotation does not restart the pod.** The kubelet refreshes the mounted Secret in place, but the
  collector reads the files once at startup — roll the deployment after a renewal
  (`kubectl -n observability rollout restart deploy/otelcollector`), or let cert-manager's reloader
  do it.
- **`defaultMode: 0400` plus a non-root container needs a matching `fsGroup`.** If the container
  cannot read the key, add `podSecurityContext.fsGroup` for the uid the image runs as.
- Keep `health_check` unencrypted, or give the probes `scheme: HTTPS` — a probe that cannot validate
  the certificate marks the pod unready and the rollout never completes.
