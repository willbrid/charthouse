# Keeping the collector configuration as a real file

Past a handful of pipelines, an inline `config:` block inside a values file stops being reviewable:
no editor validates it, and a YAML indentation mistake surfaces as a collector crash loop. This
scenario keeps `otel-collector-config.yaml` as its own file and hands it to Helm at install time.

## The two files

```yaml
# values-file.yaml — everything except the collector configuration
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

configmap:
  OTEL_RESOURCE_ATTRIBUTES: "deployment.environment=staging"

resources:
  requests:
    cpu: 200m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 1Gi
```

```yaml
# otel-collector-config.yaml — the collector's own file, edited on its own
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4317
      http:
        endpoint: ${env:OTEL_COLLECTOR_POD_IP}:4318

processors:
  memory_limiter:
    check_interval: 5s
    limit_percentage: 80
    spike_limit_percentage: 25
  batch:
    timeout: 5s
    send_batch_size: 8192
  # Helm expressions are resolved by the chart before the file reaches the
  # ConfigMap, so release-dependent values need no duplication.
  resource:
    attributes:
      - key: k8s.namespace.name
        value: "{{ .Release.Namespace }}"
        action: upsert
      - key: collector.release
        value: "{{ .Release.Name }}"
        action: upsert

exporters:
  debug:
    verbosity: basic

extensions:
  health_check:
    endpoint: ${env:OTEL_COLLECTOR_POD_IP}:13133

service:
  extensions: [health_check]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resource, batch]
      exporters: [debug]
```

## Install

```bash
helm install otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --version 0.1.0 \
  --namespace observability --create-namespace \
  --values values-file.yaml \
  --set-file config=./otel-collector-config.yaml
```

The same two flags apply to `helm upgrade`. Repeat both every time — an upgrade that omits
`--set-file` falls back to the chart's default configuration.

## Verify what the collector actually got

```bash
# render without installing, to read the ConfigMap that will be created
helm template otelcollector oci://ghcr.io/willbrid/charts/otelcollector \
  --values values-file.yaml --set-file config=./otel-collector-config.yaml \
  --show-only templates/configmap-config.yaml

# after install, the file as mounted in the container
kubectl -n observability exec deploy/otelcollector -- cat /conf/otel-collector-config.yaml
```

## What to know

- **The content goes through `tpl`.** `{{ .Release.Namespace }}` and friends are resolved by Helm;
  the collector's own `${env:VAR}` placeholders are left alone because they are not Go template
  syntax. A literal `{{` you actually want in the file must be escaped as `{{ "{{" }}`.
- **The pod restarts on a configuration change**, because the deployment carries a checksum
  annotation over the ConfigMap. No manual rollout needed after an upgrade.
- **Validate before shipping.** The collector binary checks its own file:
  `docker run --rm -v $PWD:/c otel/opentelemetry-collector-contrib:0.157.0 validate --config=/c/otel-collector-config.yaml`
  turns a crash loop into an error message on your laptop.
- Keep the config file next to the values file in git. Reviewing them together is the point of
  splitting them.
