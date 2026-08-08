# A single-node cluster for development

One pod carrying both roles, replication factor 1 everywhere, small heap. This fits on a laptop
cluster and starts in under a minute — and it tolerates the loss of nothing, which is the whole
point of keeping it out of anything shared.

## Values

```yaml
# values-dev.yaml
# One node: it is its own metadata quorum of one, and its own broker.
replicaCount: 1

image:
  repository: apache/kafka
  tag: "4.2.0"
  pullPolicy: IfNotPresent

kraft:
  # Generate your own even here — it is written into the storage on first format
  # and can never change afterwards:
  #   docker run --rm apache/kafka:4.2.0 /opt/kafka/bin/kafka-storage.sh random-uuid
  clusterId: "4L6g3nShT-eMCtK--X86sw"
  role: "controller,broker"
  quorum:
    mode: dynamic

listeners:
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

# Every replication factor must come down to 1: with a single broker, a topic
# asking for 3 replicas is simply never created, and the internal topics that
# ask for it block the cluster on first use.
config:
  offsets.topic.replication.factor: 1
  transaction.state.log.replication.factor: 1
  transaction.state.log.min.isr: 1
  default.replication.factor: 1
  min.insync.replicas: 1
  num.partitions: 1
  # Convenient here, a source of stray topics anywhere else.
  auto.create.topics.enable: true
  log.retention.hours: 24

extraEnv:
  # Not a Kafka property, so it belongs here rather than in `config`.
  - name: KAFKA_HEAP_OPTS
    value: "-Xms512m -Xmx512m"

persistence:
  enabled: true
  size: 5Gi
  storageClassName: ""       # "" takes the cluster default StorageClass

# A budget over a single pod would block every node drain.
podDisruptionBudget:
  enabled: false

resources:
  requests:
    cpu: 250m
    memory: 1Gi
  limits:
    cpu: "2"
    memory: 2Gi
```

## Install

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 \
  --namespace kafka --create-namespace \
  --values values-dev.yaml

kubectl -n kafka rollout status statefulset/kafka
helm test kafka --namespace kafka
```

## Use it

```bash
kubectl -n kafka exec -it kafka-0 -- bash

/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic demo --partitions 3 --replication-factor 1

/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic demo

/opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic demo
# type a few lines, Ctrl-D

/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic demo --from-beginning --timeout-ms 5000
```

From another pod in the cluster, `bootstrap.servers` is `kafka.kafka.svc.cluster.local:9094`.

## What to know

- **`replicaCount` is not a scaling knob.** It drives the node ids, the quorum endpoints and the
  advertised addresses. Going from 1 to 3 later means the two new nodes join a quorum that pod 0
  formatted alone — which works with `mode: dynamic`, but is a topology change, not a resize. Start
  at 3 for anything you intend to keep.
- **`persistence.enabled: false` is tempting here and still wrong.** An `emptyDir` loses the
  metadata log the moment the pod is rescheduled, and a controller without its metadata log has no
  cluster. The 5Gi claim above costs nothing on a local StorageClass.
- **`mode: dynamic` requires Kafka 4.2 or later.** On 4.0 or 4.1 the property is silently ignored
  and every node but pod 0 stays an observer — see [Static quorum](06-static-quorum.md).
- **Heap small, memory limit larger.** Kafka relies on the page cache for reads; a limit close to
  `-Xmx` gives it no cache at all. Half the limit is a reasonable heap.
- Move to [Production cluster](02-production-cluster.md) as soon as more than one person depends on
  it.
