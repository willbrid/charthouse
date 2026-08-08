# Quick start — an aggregator that prints what it receives

One Fluent Bit taking logs over the `forward` protocol and printing them to its own stdout. Nothing
is stored and nothing leaves the cluster: install this first to prove your senders reach the
aggregator, then change the `[OUTPUT]` section once they do.

## Values

```yaml
# values-quickstart.yaml
kind: Deployment
replicaCount: 1

image:
  repository: fluent/fluent-bit
  tag: "5.0.9"          # pin it: plugin options move between minor releases
  pullPolicy: IfNotPresent

command:
  - "/fluent-bit/bin/fluent-bit"

configMountPath: /fluent-bit/etc
configFileName: fluent-bit.conf

service:
  type: ClusterIP
  ports:
    # The HTTP monitoring server: health, metrics, and the API the probes use.
    - name: health
      port: 2020
      targetPort: 2020
      protocol: TCP
    - name: forward
      port: 24224
      targetPort: 24224
      protocol: TCP

config: |
  [SERVICE]
      daemon        Off
      flush         1
      log_level     info
      http_server   On
      http_listen   0.0.0.0
      http_port     2020
      # Without this, /api/v1/health answers 404 and the readiness probe never
      # succeeds — the pod stays Running and never Ready.
      health_check  On

  [INPUT]
      name          forward
      listen        0.0.0.0
      port          24224
      # Caps what one sender can hold in memory before Fluent Bit pauses it.
      mem_buf_limit 10MB

  [OUTPUT]
      name          stdout
      match         *
      format        json_lines

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi
```

## Install

```bash
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging --create-namespace \
  --values values-quickstart.yaml
```

## Send it a record and watch it arrive

```bash
kubectl -n logging port-forward svc/fluentbit 24224:24224 &

# forward protocol, msgpack — easiest to produce with fluent-bit itself
kubectl -n logging run sender --rm -it --restart=Never \
  --image fluent/fluent-bit:5.0.9 -- \
  /fluent-bit/bin/fluent-bit \
    -i dummy -p 'dummy={"hello":"from a sender"}' \
    -o forward -p host=fluentbit.logging.svc.cluster.local -p port=24224

kubectl -n logging logs deploy/fluentbit --tail=20     # the record is printed here
```

Senders inside the cluster point at `fluentbit.logging.svc.cluster.local:24224`.

## Check the pipeline from the monitoring server

```bash
kubectl -n logging port-forward svc/fluentbit 2020:2020 &
curl -s localhost:2020/api/v1/health          # the readiness probe target
curl -s localhost:2020/api/v1/metrics | jq .  # per-plugin records in/out and retries
```

## What to know

- **A port in `service.ports` and an `[INPUT]` in the config are two halves of the same thing.** A
  port without its input publishes something nothing listens on; an input without its port is
  unreachable through the service.
- **`stdout` is for proving connectivity, not for running.** Its output is unbounded and lands in
  the pod logs, which something else then collects — usually the very collector you are building.
  Point it at a real backend next: [Node logs with a DaemonSet](02-node-logs-daemonset.md).
- **Do not mount over `/fluent-bit/etc` if you need the built-in parsers.** That directory ships
  `parsers.conf` in the image, and `configMountPath` hides it. Set `configMountPath` to
  `/fluent-bit/etc/conf` and reference `/fluent-bit/etc/parsers.conf` by absolute path when you need
  both.
- The chart appends `-c <configMountPath>/<configFileName>` to `command` on its own — only the
  binary and its extra flags belong in that value.
