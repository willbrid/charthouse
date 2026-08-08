# Static quorum — Kafka 4.0 and 4.1, and per-pod addressing

The chart defaults to `kraft.quorum.mode: dynamic`, which needs Kafka **4.2 or later**. Two
situations call for the older `static` mode instead:

1. you are running Kafka 4.0 or 4.1;
2. you need a per-pod `advertisedHost`, which the dynamic mode's formatting step cannot express —
   see [External access](04-external-access.md).

In static mode the full voter set is frozen in every node's configuration through
`controller.quorum.voters`, and the image entrypoint formats the storage itself.

## Values

```yaml
# values-static.yaml
replicaCount: 3

image:
  repository: apache/kafka
  # The reason for this page. On 4.1 and earlier,
  # controller.quorum.auto.join.enable does not exist: the dynamic mode's
  # property is silently ignored and every node but pod 0 stays an observer —
  # a cluster that looks healthy with a quorum of one.
  tag: "4.1.0"
  pullPolicy: IfNotPresent

kraft:
  clusterId: "REPLACE-WITH-YOUR-OWN-UUID"
  role: "controller,broker"
  quorum:
    mode: static
    # Left empty: the chart generates one entry per pod, in the
    # <id>@<pod>.<headless>.<namespace>.svc.<domain>:<port> form the property
    # expects. Only a broker-only release has to fill this in.
    voters: []

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

config:
  offsets.topic.replication.factor: 3
  transaction.state.log.replication.factor: 3
  transaction.state.log.min.isr: 2
  default.replication.factor: 3
  min.insync.replicas: 2
  num.partitions: 6
  auto.create.topics.enable: false
  log.retention.hours: 168

extraEnv:
  - name: KAFKA_HEAP_OPTS
    value: "-Xms4g -Xmx4g"

persistence:
  enabled: true
  size: 500Gi
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
            app.kubernetes.io/instance: kafka

resources:
  requests:
    cpu: "2"
    memory: 16Gi
  limits:
    cpu: "4"
    memory: 16Gi
```

## Install

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 \
  --namespace kafka --create-namespace \
  --values values-static.yaml

kubectl -n kafka rollout status statefulset/kafka --timeout=10m
helm test kafka --namespace kafka
```

## Verify the quorum has three voters, not one

This is the check that catches the mode/version mismatch, and the only one that does — everything
else looks healthy either way.

```bash
kubectl -n kafka exec kafka-0 -- \
  /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status

# CurrentVoters must list three ids. One id and two entries under
# CurrentObservers means the quorum never formed as intended.
```

```bash
# what each node was actually told
kubectl -n kafka exec kafka-0 -- env | grep KAFKA_CONTROLLER_QUORUM
# static mode  → KAFKA_CONTROLLER_QUORUM_VOTERS=0@kafka-0...:9093,1@…,2@…
# dynamic mode → KAFKA_CONTROLLER_QUORUM_BOOTSTRAP_SERVERS=… plus AUTO_JOIN_ENABLE=true
```

## What to know

- **The two modes are mutually exclusive at the storage level.** Kafka rejects a node formatted for
  one mode and configured for the other, so the chart emits exactly one of the two properties.
  Switching an existing cluster is a migration, not an upgrade — plan it as one.
- **The voter set is frozen.** Changing `replicaCount` regenerates `controller.quorum.voters` for
  every node, which means every node must be restarted with the new list before the new members can
  vote. Growing a static cluster is a deliberate, ordered operation; a dynamic one grows on its own.
- **Static mode formats through the image entrypoint**, so there is no formatting init container and
  no `-format` ConfigMap in the rendered output. That is also why a per-pod `advertisedHost` works
  here and not under `dynamic`: the entrypoint reads environment variables Kubernetes has already
  expanded.
- **Keep the voter count odd.** 3 tolerates one node down, 5 tolerates two. An even count buys
  nothing and costs a node.
- **Move to `dynamic` when you move to 4.2.** It is the current mechanism, the voter set becomes
  growable, and the static property is deprecated — unless the per-pod addressing of
  [External access](04-external-access.md) keeps you here.
