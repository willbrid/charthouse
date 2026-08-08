# A three-node production cluster

Three combined controller/broker nodes, spread across failure domains, on fast storage, with a
disruption budget that keeps a node drain from taking the quorum with it. This is the default shape
of the chart, filled in with the values that actually matter.

## Values

```yaml
# values-production.yaml
# Odd number, and the size of the metadata quorum: 3 tolerates one node down,
# 5 tolerates two.
replicaCount: 3

image:
  repository: apache/kafka
  tag: "4.2.0"
  pullPolicy: IfNotPresent

kraft:
  # Generated once, for this cluster, and never changed. A node whose storage
  # holds a different id refuses to start:
  #   docker run --rm apache/kafka:4.2.0 /opt/kafka/bin/kafka-storage.sh random-uuid
  clusterId: "REPLACE-WITH-YOUR-OWN-UUID"
  role: "controller,broker"
  quorum:
    mode: dynamic

listeners:
  controller:
    name: CONTROLLER
    port: 9093
    securityProtocol: PLAINTEXT
  broker:
    # What brokers exchange between themselves — replication traffic.
    - name: INTERNAL
      port: 9092
      securityProtocol: PLAINTEXT
    # Applications. Separate from INTERNAL so authentication can be tightened
    # here without touching replication — see 05-sasl-and-tls.md.
    - name: CLIENT
      port: 9094
      securityProtocol: PLAINTEXT
  interBrokerListenerName: "INTERNAL"

config:
  # Three replicas of the internal topics, tolerating one broker down while
  # still accepting writes.
  offsets.topic.replication.factor: 3
  transaction.state.log.replication.factor: 3
  transaction.state.log.min.isr: 2
  default.replication.factor: 3
  # acks=all plus min.insync.replicas=2 is the pair that makes a write durable:
  # a produce is only acknowledged once two replicas hold it.
  min.insync.replicas: 2
  num.partitions: 6
  auto.create.topics.enable: false
  log.retention.hours: 168
  # Bound the disk by size as well as by time — retention.hours alone lets a
  # traffic spike fill the volume.
  log.retention.bytes: 53687091200      # 50Gi per partition replica
  num.network.threads: 6
  num.io.threads: 16
  # Unclean election trades durability for availability. Leave it off.
  unclean.leader.election.enable: false

extraEnv:
  # A quarter of the memory limit. The rest is page cache, which is what makes
  # reads cheap — a heap sized close to the limit defeats the whole design.
  - name: KAFKA_HEAP_OPTS
    value: "-Xms4g -Xmx4g"

persistence:
  enabled: true
  name: data
  size: 500Gi
  accessModes:
    - ReadWriteOnce
  # A broker wants local or network SSD. A slow class shows up as latency on
  # every produce, and as hours on a replica rebuild.
  storageClassName: fast-ssd
  mountPath: /var/lib/kafka/data

statefulSet:
  # Not for speed: with OrderedReady, pod 1 is not created until pod 0 is ready,
  # and a node of a quorum of 3 cannot become ready before the other two exist.
  # The install would deadlock.
  podManagementPolicy: Parallel
  updateStrategy:
    type: RollingUpdate
  # Time for a broker to transfer the partitions it leads and flush before it is
  # killed. Cutting it short forces a log recovery on the next start.
  terminationGracePeriodSeconds: 300
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Retain
    whenScaled: Retain

# Stops a node drain from taking a second broker down while the first is still
# catching up.
podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

# Three replicas of a partition on one node survive nothing. This is what makes
# the replication factor mean something.
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: kafka
            app.kubernetes.io/instance: kafka

# And one per zone where the cluster has three.
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
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

# Recovering a large log directory after an unclean shutdown takes minutes.
# 30 × 10s buys five of them before the pod is declared failed.
startupProbe:
  failureThreshold: 30
  periodSeconds: 10
```

## Install

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 \
  --namespace kafka --create-namespace \
  --values values-production.yaml

kubectl -n kafka rollout status statefulset/kafka --timeout=10m
helm test kafka --namespace kafka
```

## Verify the cluster is really a cluster

```bash
kubectl -n kafka exec -it kafka-0 -- bash

# three voters, one leader — not one voter and two observers
/opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server localhost:9092 describe --status

# three brokers registered
/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 | grep -c "id:"

# a topic whose partitions are spread and fully in sync
/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic orders --partitions 6 --replication-factor 3
/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic orders
# every partition: Isr with three entries, Leader varying across brokers
```

```bash
# pods on three different nodes
kubectl -n kafka get pods -o wide
```

## What to know

- **`min.insync.replicas: 2` only does anything with `acks=all` on the producer.** Together they
  mean a write is acknowledged once two replicas hold it, and a partition down to one in-sync
  replica refuses writes rather than accepting data it could lose. Either half alone is decorative.
- **`requiredDuringScheduling` anti-affinity means pods stay Pending** when there are fewer nodes
  than replicas. That is the honest failure — `preferred` would happily co-locate two brokers and
  quietly halve your fault tolerance.
- **The PVCs survive `helm uninstall`**, and `whenDeleted: Retain` makes that explicit. Deleting a
  Kafka cluster's data should take a second, deliberate command:
  `kubectl -n kafka delete pvc -l app.kubernetes.io/instance=kafka`.
- **A rolling upgrade takes as long as `terminationGracePeriodSeconds` × replicas**, at worst. Five
  minutes per broker on a large cluster is normal and is not a hang.
- **Growing the cluster does not move existing partitions.** New brokers stay empty until you
  reassign partitions onto them with `kafka-reassign-partitions.sh`.
- Splitting the roles becomes worthwhile past this size — see
  [Split controller and broker](03-split-controller-broker.md).
