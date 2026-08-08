# Split roles — dedicated controllers and dedicated brokers

Two releases of this chart: three controller-only nodes holding the metadata quorum, and however
many broker-only nodes holding the partitions. Worth doing once the cluster is large enough that a
broker restart should not disturb the quorum, or once brokers need resources controllers do not.

The two releases share one `kraft.clusterId` and must not share node ids — that is what
`kraft.nodeIdOffset` is for.

## 1. The controllers

```yaml
# values-controller.yaml
# The chart's fullnameOverride defaults to "kafka"; the two releases must not
# collide on names, services or PVCs.
fullnameOverride: "kafka-controller"

replicaCount: 3

image:
  repository: apache/kafka
  tag: "4.2.0"

kraft:
  # The same value in both files. Generated once, never changed.
  clusterId: "REPLACE-WITH-YOUR-OWN-UUID"
  role: "controller"
  # Ids 0, 1, 2.
  nodeIdOffset: 0
  quorum:
    mode: dynamic

listeners:
  controller:
    name: CONTROLLER
    port: 9093
    securityProtocol: PLAINTEXT
  # No client listener at all. The apache/kafka image refuses to start a
  # controller-only node that defines any advertised listener, so this must
  # be empty rather than merely unused.
  broker: []
  interBrokerListenerName: ""

# A controller holds no partition, so the broker-side defaults have nothing to
# act on. Dropping a default takes an explicit null — Helm merges maps, so
# `config: {}` would leave every one of them in place.
config:
  offsets.topic.replication.factor: null
  transaction.state.log.replication.factor: null
  transaction.state.log.min.isr: null
  default.replication.factor: null
  min.insync.replicas: null
  num.partitions: null
  auto.create.topics.enable: null
  log.retention.hours: null
  num.network.threads: null
  num.io.threads: null

extraEnv:
  - name: KAFKA_HEAP_OPTS
    value: "-Xms1g -Xmx1g"

# The metadata log is small, but it is the state of the quorum: losing it loses
# the cluster.
persistence:
  enabled: true
  size: 20Gi
  storageClassName: fast-ssd

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: kafka
            app.kubernetes.io/instance: kafka-controller

resources:
  requests:
    cpu: "1"
    memory: 4Gi
  limits:
    cpu: "2"
    memory: 4Gi
```

```bash
helm install kafka-controller oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 \
  --namespace kafka --create-namespace \
  --values values-controller.yaml

kubectl -n kafka rollout status statefulset/kafka-controller
```

A metadata quorum needs no broker to form, so this half stands on its own — install and verify it
before the brokers.

## 2. The brokers

```yaml
# values-broker.yaml
fullnameOverride: "kafka-broker"

replicaCount: 5

image:
  repository: apache/kafka
  tag: "4.2.0"

kraft:
  # Identical to the controller release.
  clusterId: "REPLACE-WITH-YOUR-OWN-UUID"
  role: "broker"
  # Ids 100..104. Node ids must be unique across the whole Kafka cluster, and
  # this is what keeps the brokers from colliding with controllers 0, 1, 2.
  nodeIdOffset: 100
  quorum:
    mode: dynamic
    # A broker-only release has no controller of its own, so the chart cannot
    # generate these — it asks for them rather than guessing. The names are the
    # per-pod DNS names of the controller release's headless service.
    bootstrapServers:
      - kafka-controller-0.kafka-controller-headless.kafka.svc.cluster.local:9093
      - kafka-controller-1.kafka-controller-headless.kafka.svc.cluster.local:9093
      - kafka-controller-2.kafka-controller-headless.kafka.svc.cluster.local:9093

listeners:
  # Still declared: a broker dials this listener to reach the controllers, so
  # its name, port and security protocol must match the controller release.
  controller:
    name: CONTROLLER
    port: 9093
    securityProtocol: PLAINTEXT
  broker:
    - name: INTERNAL
      port: 9092
      securityProtocol: PLAINTEXT
    - name: CLIENT
      port: 9094
      securityProtocol: PLAINTEXT
  interBrokerListenerName: "INTERNAL"

config:
  offsets.topic.replication.factor: 3
  transaction.state.log.replication.factor: 3
  transaction.state.log.min.isr: 2
  default.replication.factor: 3
  min.insync.replicas: 2
  num.partitions: 12
  auto.create.topics.enable: false
  log.retention.hours: 168
  num.network.threads: 6
  num.io.threads: 16

extraEnv:
  - name: KAFKA_HEAP_OPTS
    value: "-Xms4g -Xmx4g"

persistence:
  enabled: true
  size: 1Ti
  storageClassName: fast-ssd

statefulSet:
  podManagementPolicy: Parallel
  terminationGracePeriodSeconds: 300
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: kafka
            app.kubernetes.io/instance: kafka-broker

resources:
  requests:
    cpu: "4"
    memory: 32Gi
  limits:
    cpu: "8"
    memory: 32Gi
```

```bash
helm install kafka-broker oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 \
  --namespace kafka \
  --values values-broker.yaml

kubectl -n kafka rollout status statefulset/kafka-broker --timeout=10m
helm test kafka-broker --namespace kafka
```

Clients use `kafka-broker.kafka.svc.cluster.local:9094`.

## Verify the two halves found each other

```bash
# from a controller: three voters
kubectl -n kafka exec kafka-controller-0 -- \
  /opt/kafka/bin/kafka-metadata-quorum.sh \
    --bootstrap-controller localhost:9093 describe --status

# from a broker: five brokers registered, ids 100..104
kubectl -n kafka exec kafka-broker-0 -- \
  /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 | grep "id:"
```

## What to know

- **The `clusterId` must be byte-identical in both files.** A node whose storage was formatted with
  a different id refuses to start, with a message naming both ids — that one is at least easy to
  diagnose.
- **Colliding node ids are not.** Two nodes claiming the same id produce confusing metadata
  failures rather than a clean error. `nodeIdOffset` on the second release is what prevents it, and
  it must exceed the first release's `replicaCount`.
- **The controller listener declaration must match on both sides** — same name, same port, same
  security protocol. The brokers dial exactly what the controllers bind.
- **Install order matters once, at bootstrap.** Brokers cannot reach readiness before the quorum
  exists. Afterwards the two releases restart independently, which is the reason to split them.
- **`ct install` cannot test this**, since it installs each scenario alone and a broker-only release
  never becomes ready without its controllers. The repository ships the controller half as
  `ci/scenario-controller-only-values.yaml` and leaves the broker half to this page.
- **Scaling the brokers is now a normal operation.** Scaling the controllers is still a quorum
  change: keep it odd, and do it one node at a time.
