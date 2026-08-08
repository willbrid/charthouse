# Hardened — restricted Pod Security Standard

Fluent Bit as a non-root user with no capabilities and a read-only root filesystem, which is what a
namespace labelled `pod-security.kubernetes.io/enforce: restricted` requires. The chart sets no
security context by default, so a pod built from the default values is **rejected** in such a
namespace.

This applies to an aggregator. A node log collector is a different discussion — see the note at the
end.

## Values

```yaml
# values-hardened.yaml
kind: Deployment
replicaCount: 2

image:
  repository: fluent/fluent-bit
  tag: "5.0.9"

command:
  - "/fluent-bit/bin/fluent-bit"

configMountPath: /fluent-bit/etc
configFileName: fluent-bit.conf

podSecurityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL

# Fluent Bit talks to no Kubernetes API in this shape, so the token is one
# credential that does not need to be in the container. A DaemonSet using the
# kubernetes filter does need it — see the note below.
serviceAccount:
  create: true
  automount: false

service:
  type: ClusterIP
  ports:
    - name: health
      port: 2020
      targetPort: 2020
      protocol: TCP
    - name: forward
      port: 24224
      targetPort: 24224
      protocol: TCP

# With a read-only root filesystem, every directory Fluent Bit writes to must be
# a volume of its own.
volumes:
  - name: tmp
    emptyDir: {}
  - name: storage
    emptyDir:
      sizeLimit: 1Gi

volumeMounts:
  - name: tmp
    mountPath: /tmp
  - name: storage
    mountPath: /var/log/flb-storage

config: |
  [SERVICE]
      daemon        Off
      flush         1
      log_level     info
      http_server   On
      http_listen   0.0.0.0
      # Above 1024: an unprivileged process cannot bind a privileged port once
      # CAP_NET_BIND_SERVICE has been dropped.
      http_port     2020
      health_check  On
      storage.path  /var/log/flb-storage/

  [INPUT]
      name          forward
      listen        0.0.0.0
      port          24224
      storage.type  filesystem
      mem_buf_limit 10MB

  [OUTPUT]
      name          stdout
      match         *

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## Install

```bash
kubectl create namespace logging
kubectl label namespace logging \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest

helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging \
  --values values-hardened.yaml
```

Testing the labels alone is quicker with `--dry-run=server`: the admission webhook rejects a
non-conforming pod at that point, before any object is created.

## Verify

```bash
kubectl -n logging get pod -l app.kubernetes.io/name=fluentbit \
  -o jsonpath='{.items[0].spec.containers[0].securityContext}{"\n"}'

kubectl -n logging exec deploy/fluentbit -- id           # uid=65532
kubectl -n logging exec deploy/fluentbit -- sh -c 'touch /probe' || echo "read-only root: expected"
# no API token in the container
kubectl -n logging exec deploy/fluentbit -- ls /var/run/secrets/kubernetes.io 2>&1 || echo "no token: expected"
```

## What to know

- **`readOnlyRootFilesystem` is what breaks things, not the uid.** Anything Fluent Bit writes —
  `storage.path`, the tail position database, `/tmp` — needs its own volume. The symptom is a crash
  at startup naming the exact path, so add the mount it asks for.
- **Ports below 1024 are out.** Dropping `ALL` capabilities removes `CAP_NET_BIND_SERVICE`, so a
  syslog input on 514 cannot bind. Listen on 5140 and let the Service map 514 to it, or keep that
  one capability.
- **`restricted` also refuses `allowPrivilegeEscalation: true`, any added capability and a missing
  `seccompProfile`.** All four are set above; drop one and admission rejects the pod.
- **A node log collector cannot be this pod.** Reading `/var/log/containers` means a `hostPath`
  mount, which `restricted` forbids outright, and the files are usually root-owned. Run
  [the DaemonSet](02-node-logs-daemonset.md) in its own namespace under `privileged` or `baseline`,
  and keep `restricted` for the aggregators — splitting the two is the point of separating them.
- **`automount: false` only works while nothing queries the API.** Turn it back on the moment you
  add the `kubernetes` filter, or every lookup fails with no token to present.
