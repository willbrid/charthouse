# Reaching the cluster from outside Kubernetes

Kafka clients connect twice. First they bootstrap against any broker and are told which broker leads
which partition; then they dial **that specific broker**, at the address it advertises. Publishing
the bootstrap step is easy. Making each broker individually reachable from outside is the whole
problem, and it constrains which quorum mode you can use.

## Case A — one external address for the whole release

Fits a single-broker cluster (development, staging) or a setup where a Kafka-aware proxy sits in
front and handles broker routing itself.

```yaml
# values-external-single.yaml
replicaCount: 1

image:
  repository: apache/kafka
  tag: "4.2.0"

kraft:
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
    # In-cluster traffic, advertised under the pod DNS name as usual.
    - name: INTERNAL
      port: 9092
      securityProtocol: PLAINTEXT
    # Outside clients. advertisedHost is what they are told to come back to,
    # so it must resolve from where they run — not from inside the cluster.
    - name: EXTERNAL
      port: 9095
      securityProtocol: PLAINTEXT
      advertisedHost: kafka.example.com
      advertisedPort: 9095
  interBrokerListenerName: "INTERNAL"

service:
  type: LoadBalancer
  annotations:
    # Point kafka.example.com at the address this allocates.
    external-dns.alpha.kubernetes.io/hostname: kafka.example.com

config:
  offsets.topic.replication.factor: 1
  transaction.state.log.replication.factor: 1
  transaction.state.log.min.isr: 1
  default.replication.factor: 1
  min.insync.replicas: 1
  num.partitions: 3
  auto.create.topics.enable: false

persistence:
  enabled: true
  size: 50Gi

podDisruptionBudget:
  enabled: false

resources:
  requests:
    cpu: "1"
    memory: 4Gi
  limits:
    cpu: "2"
    memory: 4Gi
```

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 --namespace kafka --create-namespace \
  --values values-external-single.yaml

# from outside
kafka-topics.sh --bootstrap-server kafka.example.com:9095 --list
```

With more than one broker this **breaks in a way that looks like it works**: bootstrap succeeds,
metadata comes back naming `kafka.example.com:9095` for every partition, and every subsequent
request lands on whichever broker the load balancer picks — including brokers that do not lead the
partition. Producers then loop on `NOT_LEADER_OR_FOLLOWER`.

## Case B — a distinct address per broker

Each pod must advertise its own hostname. `advertisedHost` is one string for the whole set, but the
container expands `$(POD_NAME)` — so `$(POD_NAME).kafka.example.com` gives pod 0
`kafka-0.kafka.example.com`, pod 1 `kafka-1.kafka.example.com`, and so on.

**This requires `kraft.quorum.mode: static`.** With `mode: dynamic` the chart formats the storage
from an init container that hands the rendered properties file to `kafka-storage format`, and that
tool parses `advertised.listeners` before any shell expands anything:

```
java.lang.IllegalArgumentException: Error creating broker listeners from
'[..., EXTERNAL://$(POD_NAME).kafka.example.com:9095]':
Unable to parse EXTERNAL://$(POD_NAME).kafka.example.com:9095 to a broker endpoint
```

In `static` mode the image entrypoint does the formatting instead, from environment variables
Kubernetes has already expanded, and the reference resolves.

```yaml
# values-external-perpod.yaml
replicaCount: 3

image:
  repository: apache/kafka
  tag: "4.2.0"

kraft:
  clusterId: "REPLACE-WITH-YOUR-OWN-UUID"
  role: "controller,broker"
  quorum:
    # Required by the per-pod advertisedHost below. The full voter set is frozen
    # in every node's configuration; the chart generates it from replicaCount.
    mode: static

listeners:
  controller:
    name: CONTROLLER
    port: 9093
    securityProtocol: PLAINTEXT
  broker:
    - name: INTERNAL
      port: 9092
      securityProtocol: PLAINTEXT
    - name: EXTERNAL
      port: 9095
      securityProtocol: PLAINTEXT
      # Expanded per pod by Kubernetes: kafka-0.kafka.example.com, …
      advertisedHost: "$(POD_NAME).kafka.example.com"
      advertisedPort: 9095
  interBrokerListenerName: "INTERNAL"

# The chart's own Service still publishes the bootstrap step in-cluster; the
# per-pod Services below are what outside clients dial.
service:
  type: ClusterIP

config:
  offsets.topic.replication.factor: 3
  transaction.state.log.replication.factor: 3
  transaction.state.log.min.isr: 2
  default.replication.factor: 3
  min.insync.replicas: 2
  num.partitions: 6
  auto.create.topics.enable: false

persistence:
  enabled: true
  size: 200Gi
  storageClassName: fast-ssd

statefulSet:
  podManagementPolicy: Parallel
  terminationGracePeriodSeconds: 300

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
    memory: 8Gi
  limits:
    cpu: "4"
    memory: 8Gi
```

### The per-pod Services, created outside the chart

One per ordinal, each selecting a single pod through `statefulset.kubernetes.io/pod-name`:

```yaml
# kafka-external-services.yaml
apiVersion: v1
kind: Service
metadata:
  name: kafka-external-0
  namespace: kafka
  annotations:
    external-dns.alpha.kubernetes.io/hostname: kafka-0.kafka.example.com
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: kafka
    app.kubernetes.io/instance: kafka
    statefulset.kubernetes.io/pod-name: kafka-0
  ports:
    - name: external
      port: 9095
      targetPort: 9095
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-external-1
  namespace: kafka
  annotations:
    external-dns.alpha.kubernetes.io/hostname: kafka-1.kafka.example.com
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: kafka
    app.kubernetes.io/instance: kafka
    statefulset.kubernetes.io/pod-name: kafka-1
  ports:
    - name: external
      port: 9095
      targetPort: 9095
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-external-2
  namespace: kafka
  annotations:
    external-dns.alpha.kubernetes.io/hostname: kafka-2.kafka.example.com
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: kafka
    app.kubernetes.io/instance: kafka
    statefulset.kubernetes.io/pod-name: kafka-2
  ports:
    - name: external
      port: 9095
      targetPort: 9095
      protocol: TCP
```

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 --namespace kafka --create-namespace \
  --values values-external-perpod.yaml
kubectl apply -f kafka-external-services.yaml
```

## Verify the advertised addresses are the ones clients can reach

```bash
# what each broker tells clients to come back to
kubectl -n kafka exec kafka-0 -- env | grep KAFKA_ADVERTISED_LISTENERS

# from outside, bootstrap then check the metadata names real hostnames
kafka-broker-api-versions.sh --bootstrap-server kafka-0.kafka.example.com:9095 | head

# each name must resolve from where the client runs, not from the cluster
dig +short kafka-0.kafka.example.com
```

## What to know

- **The bootstrap address is not the problem; the second hop is.** Almost every "it connects then
  times out" report on external Kafka access is a client that bootstrapped fine and cannot reach the
  address it was handed. Check `KAFKA_ADVERTISED_LISTENERS` first, always.
- **Do not put an external listener on `PLAINTEXT` outside a private network.** The example above
  keeps it plaintext to isolate one variable; a real external listener wants `SASL_SSL` — see
  [SASL and TLS](05-sasl-and-tls.md).
- **`static` mode freezes the voter set in every node's configuration.** Growing the cluster then
  means updating all of them and restarting, which is the trade you accept for per-pod external
  addressing. [Static quorum](06-static-quorum.md) covers the mode itself.
- **`advertisedPort` is one value for the whole set**, so per-pod *ports* on a shared hostname are
  not available at all — the per-pod Service approach above is the supported route.
- **Cross-zone and egress traffic is billed.** A consumer outside the cluster fetching from three
  brokers pays three times; `client.rack` and follower fetching are the usual mitigation, and
  neither is configured by this chart.
