# YAML configuration instead of the classic format

Fluent Bit reads either format, and the file name is what selects it: `fluent-bit.conf` gives the
classic INI-like sections, `fluent-bit.yaml` gives YAML. In YAML mode `config` and `parsers.content`
stop being opaque strings and become real YAML mappings, which your editor validates and a diff
reads properly.

## Values

```yaml
# values-yaml-config.yaml
kind: Deployment
replicaCount: 2

image:
  repository: fluent/fluent-bit
  tag: "5.0.9"

command:
  - "/fluent-bit/bin/fluent-bit"

configMountPath: /fluent-bit/etc
# This one line is the whole switch. The chart rejects any other name than
# fluent-bit.conf or fluent-bit.yaml.
configFileName: fluent-bit.yaml

secret:
  ES_PASSWORD: "changeme"

configmap:
  ES_HOST: "elasticsearch.logging.svc.cluster.local"
  FLB_LOG_LEVEL: "info"

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

# A mapping, not a string: the chart serialises it with toYaml.
config:
  service:
    daemon: off
    flush: 1
    log_level: ${FLB_LOG_LEVEL}
    http_server: on
    http_listen: 0.0.0.0
    http_port: 2020
    health_check: on
    parsers_file: custom_parsers.yaml

  pipeline:
    inputs:
      - name: forward
        listen: 0.0.0.0
        port: 24224
        mem_buf_limit: 10MB

    filters:
      # Turn a JSON application log into real fields instead of one blob.
      - name: parser
        match: "app.*"
        key_name: log
        parser: app_json
        reserve_data: true
      # Records with no severity are noise nobody queries.
      - name: grep
        match: "app.*"
        regex: level (info|warn|error|fatal)

    outputs:
      - name: es
        match: "*"
        host: ${ES_HOST}
        port: 9200
        http_user: fluentbit
        http_passwd: ${ES_PASSWORD}
        index: applogs
        # Elasticsearch 8 removed mapping types; without this the bulk request
        # is rejected with an error mentioning _type.
        suppress_type_name: on
        retry_limit: 5

parsers:
  fileName: custom_parsers.yaml
  content:
    parsers:
      - name: app_json
        format: json
        time_key: timestamp
        time_format: "%Y-%m-%dT%H:%M:%S.%L%z"
        time_keep: on

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
helm install fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --version 0.2.0 \
  --namespace logging --create-namespace \
  --values values-yaml-config.yaml
```

## Verify what was rendered

```bash
# read the ConfigMap before creating anything
helm template fluentbit oci://ghcr.io/willbrid/charts/fluentbit \
  --values values-yaml-config.yaml \
  --show-only templates/configmap-config.yaml

# the file as mounted in the container
kubectl -n logging exec deploy/fluentbit -- cat /fluent-bit/etc/fluent-bit.yaml
```

## What to know

- **`on` and `off` are booleans in YAML.** `daemon: off` reaches Fluent Bit as `false`, which it
  accepts; but a value like `Off` quoted differently, or a plugin option expecting the literal
  string, can surprise you. When in doubt, quote it: `daemon: "off"`.
- **The parsers file must have a matching extension.** `parsers.fileName` ends in `.yaml` here and
  its content is a mapping with a top-level `parsers:` key — the classic `[PARSER]` blocks are not
  valid in a `.yaml` file, and vice versa.
- **`parsers_file` is resolved relative to the configuration file**, so both land in
  `configMountPath` and the bare file name is enough.
- **Both formats support the same plugins.** The choice is about reviewability, not capability, and
  it can be changed later — the pipeline translates one-to-one.
- **YAML mode also unlocks `processors`**, the newer per-plugin transformation blocks that have no
  classic-format equivalent. That is the one real functional difference.
- **Keeping the file outside the values** works with either extension:
  `--set-file config=./fluent-bit.yaml --set-file parsers.content=./custom_parsers.yaml`. The content
  still goes through `tpl`, so `{{ .Release.Namespace }}` is resolved while Fluent Bit's own `${VAR}`
  placeholders are left alone.
