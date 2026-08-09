# TLS termination

HAProxy terminates TLS at the edge and talks plain HTTP to the backends behind it. The only awkward
part in Kubernetes is the certificate format: HAProxy wants **one PEM file holding the private key
and the certificate chain**, and a `kubernetes.io/tls` Secret holds two separate keys. This page
covers both shapes.

## The certificate

A `kubernetes.io/tls` Secret has `tls.crt` and `tls.key`. HAProxy's `crt` argument wants them
concatenated, key first:

```bash
# From an existing tls Secret, into a generic one HAProxy can use
kubectl get secret my-tls -n edge -o jsonpath='{.data.tls\.key}' | base64 -d  > tls.pem
kubectl get secret my-tls -n edge -o jsonpath='{.data.tls\.crt}' | base64 -d >> tls.pem

kubectl create secret generic haproxy-tls -n edge --from-file=tls.pem
```

With cert-manager, ask for the combined key directly in the `Certificate` and skip the manual step:

```yaml
spec:
  secretName: haproxy-tls
  additionalOutputFormats:
    - type: CombinedPEM      # adds a `tls-combined.pem` key to the Secret
```

(`additionalOutputFormats` needs the `AdditionalCertificateOutputFormats` feature gate on the
cert-manager controller.)

## Values

```yaml
# values-tls.yaml
kind: Deployment
replicaCount: 2

image:
  repository: haproxy
  tag: "3.4"
  pullPolicy: IfNotPresent

# The Secret is mounted as a directory. `crt` accepts a directory too, which is how
# you serve several certificates and let SNI pick between them — every PEM in the
# directory is loaded.
volumes:
  - name: certs
    secret:
      secretName: haproxy-tls
      optional: false

volumeMounts:
  - name: certs
    mountPath: /etc/haproxy/certs
    readOnly: true

config: |
  global
      log stdout format raw local0 info
      maxconn 8192
      # Applies to every `bind ... ssl` line below. TLS 1.2 is the floor; drop to
      # ssl-min-ver TLSv1.3 once you know no client needs less.
      ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
      ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
      ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384

  defaults
      log     global
      mode    http
      option  httplog
      option  dontlognull
      retries 2
      timeout connect 5s
      timeout client  50s
      timeout server  50s
      timeout http-request 10s

  frontend health
      bind *:8404
      mode http
      http-request set-log-level silent
      monitor-uri /healthz
      http-request use-service prometheus-exporter if { path /metrics }
      stats enable
      stats uri /stats

  # Plain HTTP exists only to send clients to HTTPS.
  frontend http_in
      bind *:8080
      mode http
      http-request redirect scheme https code 301

  frontend https_in
      bind *:8443 ssl crt /etc/haproxy/certs/
      mode http
      # Tell the backends the client spoke TLS, and tell the client to keep doing so.
      http-request set-header X-Forwarded-Proto https
      http-response set-header Strict-Transport-Security "max-age=31536000; includeSubDomains"
      default_backend app

  backend app
      mode http
      balance roundrobin
      option httpchk GET /healthz
      server app1 app.default.svc.cluster.local:8080 check

service:
  enabled: true
  type: LoadBalancer
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
    - name: health
      port: 8404
      targetPort: 8404
      protocol: TCP

# Unchanged from the chart defaults: TLS termination needs no extra privilege. The
# private key is read at startup, as uid 99, from a read-only mount.
securityContext:
  capabilities:
    drop: [ALL]
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true

resources:
  requests:
    cpu: 200m
    memory: 128Mi
  limits:
    memory: 512Mi
```

## Install

```bash
helm install haproxy oci://ghcr.io/willbrid/charts/haproxy \
  --version 0.1.0 \
  --namespace edge --create-namespace \
  --values values-tls.yaml
```

## Verify

```bash
kubectl port-forward -n edge svc/haproxy 8443:443

# What certificate is served, and over which protocol
openssl s_client -connect 127.0.0.1:8443 -servername api.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates

# The redirect from plain HTTP
kubectl port-forward -n edge svc/haproxy 8080:80
curl -i http://127.0.0.1:8080/            # 301 → https://
```

A certificate HAProxy failed to load is not a silent failure: the process refuses to start and the
`config-check` init container says so first.

```bash
kubectl logs -n edge <pod> -c config-check
# [ALERT] ... unable to load SSL certificate file '/etc/haproxy/certs/tls.pem'
```

## Renewal

A renewed certificate is a new Secret content. The mounted files are updated within a minute or so,
but **HAProxy does not reload on its own** — it read the key at startup and keeps using it. Two ways
to pick up the new one:

```bash
# Roll the pods (simple, and what an upgrade does anyway)
kubectl rollout restart deploy/haproxy -n edge

# Or reload in place, which is why the command carries -W
kubectl exec -n edge deploy/haproxy -- kill -USR2 1
```

Automating this belongs outside the chart — a `reloader`-style controller watching the Secret, or a
CronJob doing the rollout restart.

## What to know

- **One PEM, key first.** `crt` pointing at a `tls.crt`-only file gives
  `unable to load SSL private key`. Pointing at a *directory* loads every PEM in it, which is the
  multi-certificate/SNI setup.
- **`ssl-min-ver TLSv1.2` is a floor, not a policy.** Review the cipher lists against what your
  clients actually need; the ones above are a reasonable 2026 default and will age.
- **The private key is in a Secret, which is base64, not encryption.** Restrict who can read Secrets
  in the namespace, and prefer a certificate issued to this proxy over one shared across services.
- **Terminating TLS makes the proxy the client's peer.** The backends see plain HTTP from the proxy —
  set `X-Forwarded-Proto` as above, or an application that builds absolute URLs will emit `http://`
  links. For end-to-end encryption, add `ssl verify required ca-file ...` on the `server` lines.
- **HTTP/2 works out of the box** over TLS with the ALPN defaults of recent HAProxy branches; add
  `alpn h2,http/1.1` to the `bind` line to be explicit.
