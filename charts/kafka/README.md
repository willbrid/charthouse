# kafka

Apache Kafka in **KRaft mode**, deployed as a StatefulSet.

ZooKeeper is not supported and cannot be: it was removed from Kafka in `4.0.0`. This chart targets
`4.2.0` and later, which is where the dynamic controller quorum it uses by default became able to
form on its own.

| | |
|---|---|
| Kubernetes | `1.30+` |
| Helm | `3.8+` |
| Kafka | `4.2.0+` (`4.0.0`–`4.1.x` with `kraft.quorum.mode: static`) |
| Image | [`apache/kafka`](https://hub.docker.com/r/apache/kafka) |

---

## What the chart derives for you

Kafka in KRaft needs every node to know who it is, who its peers are, which sockets it opens and
which addresses it hands out to clients. Those four things are views of one fact, and a cluster
breaks in confusing ways when they disagree. The chart therefore derives them all from three
values and never asks you to repeat one:

| You declare | The chart generates |
|-------------|---------------------|
| `replicaCount` | `controller.quorum.bootstrap.servers` (or `controller.quorum.voters`), one endpoint per pod |
| `kraft.role` | `process.roles`, which listeners are bound, whether anything is advertised at all |
| `listeners` | `listeners`, `advertised.listeners`, `listener.security.protocol.map`, `controller.listener.names`, `inter.broker.listener.name`, the Service ports, the probe target |
| the StatefulSet ordinal | `node.id` |
| `persistence.mountPath` | `log.dirs` |

Three consequences worth knowing:

- **`node.id` is the pod ordinal**, read from the `apps.kubernetes.io/pod-index` label through the
  downward API — plus `kraft.nodeIdOffset`. Pod `kafka-2` is always node `2`, across restarts and
  reschedules.
- **Addresses are per-pod DNS names**, from the headless Service:
  `kafka-0.kafka-headless.<namespace>.svc.cluster.local`. A load-balanced address cannot work here:
  a client bootstraps against any broker, is told which broker leads which partition, then has to
  dial *that* broker.
- **A controller-only node advertises nothing.** Kafka forbids advertising the controller listener,
  and the `apache/kafka` image refuses to start a controller-only node that defines
  `advertised.listeners` at all — so the property is omitted entirely, not emptied.

---

## Configuring Kafka

Kafka is configured through `KAFKA_*` environment variables, the interface of the official image.
The naming rules, and a set of worked examples, are documented upstream:

**<https://github.com/apache/kafka/blob/trunk/docker/examples/README.md>**

You write ordinary Kafka properties in `config`, and the chart applies the conversion — `_` → `__`,
`-` → `___`, `.` → `_`, upper-cased, prefixed with `KAFKA_`:

```yaml
config:
  num.partitions: 3                              # → KAFKA_NUM_PARTITIONS
  log.retention.hours: 168                       # → KAFKA_LOG_RETENTION_HOURS
  listener.name.client.sasl.enabled.mechanisms: PLAIN
                                                 # → KAFKA_LISTENER_NAME_CLIENT_SASL_ENABLED_MECHANISMS
```

That keeps the values file readable against the Kafka documentation, which names properties, not
variables. Helm merges this map with the chart defaults, so removing one takes an explicit
`null` — `config: {}` leaves them all in place.

Anything that is *not* a Kafka property — `KAFKA_HEAP_OPTS`, `KAFKA_OPTS`, `KAFKA_JMX_OPTS` — goes
to `extraEnv` verbatim. There are also `configmap` and `secret` for bulk environment variables
mounted with `envFrom`.

The topology properties are generated and should not be repeated in `config`. Setting one anyway
overrides the generated value — an escape hatch for a topology the chart does not model, at the
cost of the consistency described above. `node.id` is the exception and is rejected outright: a
single value shared by the whole set would have every pod claim the same identity.

---

## Roles

`kraft.role` takes `controller,broker` (the default), `controller`, or `broker`.

**Combined** is one release and the right answer until the cluster is large enough that a broker
restart disturbing the quorum becomes a real cost:

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka --set replicaCount=3
```

**Split** is *two releases of this chart*, not one — the constraint that the pod count comes from
`replicaCount` means one StatefulSet holds one role. They form a single Kafka cluster by sharing
`kraft.clusterId`, and the brokers shift their ids so they cannot collide with the controllers:

```yaml
# controller.yaml
replicaCount: 3
kraft:
  clusterId: "<your-cluster-id>"
  role: controller
listeners:
  broker: []
```

```yaml
# broker.yaml
replicaCount: 5
kraft:
  clusterId: "<your-cluster-id>"     # the same one
  role: broker
  nodeIdOffset: 100                  # brokers become 100, 101, ... — never 0, 1, 2
  quorum:
    bootstrapServers:                # a broker release has no controller to derive
      - kafka-controller-0.kafka-controller-headless.kafka.svc.cluster.local:9093
      - kafka-controller-1.kafka-controller-headless.kafka.svc.cluster.local:9093
      - kafka-controller-2.kafka-controller-headless.kafka.svc.cluster.local:9093
```

```bash
helm install kafka-controller . -f controller.yaml -n kafka   # controllers first
helm install kafka-broker     . -f broker.yaml     -n kafka
```

Install the controllers first: the brokers cannot format their storage or reach readiness before a
quorum exists. `helm install --wait` on the controller release is the ordering you want. The
`NOTES.txt` of a controller-only release prints the exact `bootstrapServers` block to paste.

---

## The metadata quorum

`replicaCount` is the size of the quorum whenever the nodes carry the controller role. Use an odd
number: **3** tolerates one node down, **5** tolerates two, **1** is for development. The chart
refuses `2` — it tolerates nothing while doubling the failure surface.

Two mechanisms exist, and they are mutually exclusive; Kafka rejects a node formatted for one and
configured for the other, so the chart emits exactly one of the two properties:

| `kraft.quorum.mode` | Property | Notes |
|---------------------|----------|-------|
| `dynamic` (default) | `controller.quorum.bootstrap.servers` | KRaft version 1. Pod 0 formats as the sole initial voter, the others join through `controller.quorum.auto.join.enable`. **Needs Kafka 4.2+** — see the warning below. The set can be grown and shrunk afterwards. |
| `static` | `controller.quorum.voters` | Deprecated. The full voter set is frozen in the configuration of every node. This is the mode for Kafka 4.0 and 4.1. |

Switching mode on a running cluster is a migration, not an upgrade.

> **On Kafka 4.1 and earlier, `dynamic` fails quietly.** `controller.quorum.auto.join.enable` does
> not exist before 4.2, so Kafka drops it without a word: pod 0 forms a quorum of one, the other
> pods start, register, serve traffic — and stay observers forever. The cluster looks healthy and
> has no redundancy in its metadata quorum. Use `static` on those versions.

### Storage formatting

Who formats the storage depends on the mode, because the image can only do one of the two. Its
entrypoint runs `kafka-storage format` with `--cluster-id` and `--config` and nothing else — enough
for a static voter set, but a dynamic quorum also needs one of `--standalone` /
`--initial-controllers` / `--no-initial-controllers`, and the argument check fires *before* the
already-formatted check, so the node dies on every start whatever the volume holds.

| Mode | Formatted by | Container command |
|------|--------------|-------------------|
| `static` | the image entrypoint | untouched |
| `dynamic` | an init container, `--standalone` on pod 0 and `--no-initial-controllers` elsewhere | the image's own steps, with its formatting step skipped |

For `dynamic` the chart runs the image's `configure` and its `KafkaDockerWrapper setup` — which is
what renders `server.properties` from the `KAFKA_*` variables — then starts the broker itself. The
wrapper's formatting attempt is expected to fail and is tolerated; the configuration file is fully
written before it, which is what makes this safe. Any other failure still aborts the container.

The init container does nothing when the volume already holds a formatted log directory, so a
restart is a no-op. `kraft.format.extraArgs` reaches the format command for what the chart does not
model — `--add-scram` to seed SCRAM credentials, `--feature` to pin a feature level.

### Cluster id

`kraft.clusterId` is written to the storage at format time and **cannot change afterwards** — a node
whose volume holds a different id refuses to start. It must be identical on every node of the
cluster, including across the two releases of a split deployment.

```bash
docker run --rm apache/kafka:4.2.0 /opt/kafka/bin/kafka-storage.sh random-uuid
```

The chart ships a valid default so a first install works out of the box, and warns on install as
long as you keep it. Replace it for anything but a throwaway cluster.

---

## Listeners

Declare a listener once; the chart binds it, advertises it, maps its security protocol, exposes it
as a container port and as a Service port, and points the probes at it.

```yaml
listeners:
  controller:                      # bound only by nodes carrying the controller role
    name: CONTROLLER
    port: 9093
    securityProtocol: PLAINTEXT
  broker:                          # bound only by nodes carrying the broker role
    - name: INTERNAL
      port: 9092
      securityProtocol: PLAINTEXT
    - name: CLIENT
      port: 9094
      securityProtocol: SASL_PLAINTEXT
  interBrokerListenerName: INTERNAL
```

Names are unique across the controller entry and the broker list, as are ports — Kafka indexes
listeners by name and the pod binds every port in one network namespace. A name is capped at 15
characters: it becomes a Service port name once lower-cased.

Separating `INTERNAL` from `CLIENT` is what lets you tighten authentication on application traffic
without touching what brokers exchange between themselves.

### Reaching the cluster from outside Kubernetes

The bootstrap step is easy — a `LoadBalancer` on `service.type` publishes it. The second step is
the hard one: the client is redirected to a *specific* broker and must reach it at the address that
broker advertises, which the in-cluster DNS name is not, from outside. That needs a per-pod address:

```yaml
listeners:
  broker:
    - name: INTERNAL
      port: 9092
    - name: EXTERNAL
      port: 9095
      securityProtocol: SASL_SSL
      advertisedHost: kafka.example.com     # resolvable from where the clients run
      advertisedPort: 9095
```

`advertisedHost` is a single value for the whole set, so this form fits a setup where one hostname
front-ends the cluster. Giving each pod a distinct external address requires one Service per pod,
which is outside the scope of the chart.

---

## Injecting files

Files whose names you choose, mounted read-only into the container. This is what SASL and TLS need:
a JAAS configuration is referenced by absolute path from `KAFKA_OPTS`, and the `apache/kafka` image
derives the path of its SSL material from `/etc/kafka/secrets`.

```yaml
extraFiles:
  mountPath: /etc/kafka/secrets
  secret:                              # → Secret, for anything carrying a credential
    kafka_jaas.conf: |
      KafkaServer {
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="admin"
        password="admin-secret"
        user_admin="admin-secret"
        user_client="client-secret";
      };
  configMap: {}                        # → ConfigMap, for the rest

extraEnv:
  - name: KAFKA_OPTS
    value: "-Djava.security.auth.login.config=/etc/kafka/secrets/kafka_jaas.conf"

config:
  sasl.enabled.mechanisms: PLAIN
  listener.name.client.sasl.enabled.mechanisms: PLAIN
```

Both sources land in the same directory through a single projected volume, so a name may not appear
in both — the chart refuses rather than letting one mount shadow the other. File contents go through
`tpl`, so `{{ .Release.Namespace }}` and friends resolve. Changing a file rolls the StatefulSet: the
pods carry a checksum of it.

Loading a file from disk instead of inlining it:

```bash
helm install kafka . --set-file extraFiles.secret.kafka_jaas\.conf=./kafka_jaas.conf
```

---

## Storage

One PVC per pod, from the StatefulSet `volumeClaimTemplates`, named `data-kafka-<ordinal>` and bound
to its ordinal for the life of the pod. It holds the log directory: the partitions of a broker, and
the metadata log carrying the quorum on a controller. `log.dirs` is generated from
`persistence.mountPath`, so the two cannot drift.

```yaml
persistence:
  enabled: true
  name: data
  size: 100Gi
  accessModes: [ReadWriteOnce]
  storageClassName: fast-ssd
  mountPath: /var/lib/kafka/data
```

The PVCs survive `helm uninstall` — deleting cluster data is a deliberate, separate act. Use
`statefulSet.persistentVolumeClaimRetentionPolicy` to change that.

`persistence.enabled: false` replaces the PVC with an `emptyDir`: every partition, and a
controller's quorum state, is lost the moment a pod is rescheduled. Development only, and the chart
says so on install.

---

## Availability

- **`podManagementPolicy: Parallel`**, and not for speed. A node of a quorum cannot report ready
  before its peers exist and elect a leader, so `OrderedReady` — which waits for pod 0 before
  creating pod 1 — deadlocks the install of any multi-node cluster.
- **A PodDisruptionBudget** (`maxUnavailable: 1`) holds a node drain from taking a second pod down
  while the first is still catching up. Not rendered for a single-node set.
- **TCP probes**, deliberately. An API-level readiness check reports a broker as not ready while it
  catches up on the metadata log — which is exactly when it must stay in the set to catch up. The
  `startupProbe` allows 5 minutes by default: recovering a large log directory after an unclean
  shutdown takes minutes, and this is what buys that time without loosening liveness.
- **`terminationGracePeriodSeconds: 120`** lets a broker transfer the partitions it leads and flush.
  Cutting it short forces a recovery on the next start.
- **Spread the pods.** Three replicas of a partition on one node survive nothing. Set `affinity`
  (pod anti-affinity on `kubernetes.io/hostname`) or `topologySpreadConstraints` across zones — both
  are left empty by default because a single-node cluster cannot satisfy them.
- **Memory.** Keep the heap small (`KAFKA_HEAP_OPTS` in `extraEnv`) and leave the rest of the limit
  to the page cache, which is what makes reads cheap. A limit close to the heap defeats that.

---

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `replicaCount` | `3` | Pods in the set, and the size of the quorum when the role includes `controller` |
| `image.repository` | `apache/kafka` | `apache/kafka-native` is the GraalVM build |
| `image.tag` | `""` | Defaults to `.Chart.AppVersion` |
| `clusterDomain` | `cluster.local` | Used to build the per-pod addresses |
| `kraft.clusterId` | *(a valid placeholder)* | Immutable once formatted — **replace it** |
| `kraft.role` | `controller,broker` | `controller`, `broker`, or both |
| `kraft.nodeIdOffset` | `0` | Added to the ordinal to give `node.id` |
| `kraft.quorum.mode` | `dynamic` | `dynamic` (Kafka 4.1+) or `static` |
| `kraft.quorum.bootstrapServers` | `[]` | Required on a broker-only release |
| `kraft.quorum.voters` | `[]` | Same, for `mode: static` |
| `kraft.format.extraArgs` | `[]` | Extra flags for `kafka-storage format` |
| `listeners.controller` | `CONTROLLER:9093` | Quorum listener |
| `listeners.broker` | `INTERNAL:9092`, `CLIENT:9094` | Client-facing listeners |
| `listeners.interBrokerListenerName` | `INTERNAL` | Defaults to the first broker listener |
| `config` | *(replication 3, ISR 2, …)* | Kafka properties, converted to `KAFKA_*` |
| `extraEnv` | `[]` | Raw environment variables |
| `configmap` / `secret` | `{}` | Bulk environment variables via `envFrom` |
| `extraFiles.mountPath` | `/etc/kafka/secrets` | Where injected files land |
| `extraFiles.configMap` / `.secret` | `{}` | Files, named by you |
| `persistence.*` | `8Gi`, `ReadWriteOnce` | Per-pod PVC |
| `statefulSet.podManagementPolicy` | `Parallel` | See above — do not change lightly |
| `service.type` | `ClusterIP` | Bootstrap address; ports come from `listeners.broker` |
| `podDisruptionBudget.enabled` | `true` | `maxUnavailable: 1` |
| `tests.enabled` | `true` | `helm test` pod |

The full set, with the reasoning behind each default, is in
[`values.yaml`](values.yaml).

---

## Verifying an install

```bash
helm test kafka -n kafka

kubectl -n kafka exec -it kafka-0 -- \
  /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-controller localhost:9093 describe --status

kubectl -n kafka exec -it kafka-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

The `helm test` pod makes two checks. It lists the topics through the first `PLAINTEXT` broker
listener, which only answers once the quorum has elected a leader — a stricter check than a socket
probe. Then it counts the voters in `CurrentVoters` and fails unless there are `replicaCount` of
them.

That second check exists because pod readiness cannot see the failure that matters most here. A
node that never joined the quorum still starts, registers, and serves traffic: every pod is
`Ready`, topics are created, producers and consumers work — and the metadata log has a quorum of
one. Nothing short of counting the voters catches it. It is skipped when the quorum endpoints were
given explicitly, that quorum living in another release whose size is not this one's to assert.

The pod is not rendered at all when every listener requires authentication, since it would then
fail for reasons unrelated to the health of the cluster.

---

## CI scenarios

[`ci/`](ci/) holds the values `chart-testing` installs on a Kind cluster:

| Scenario | Covers |
|----------|--------|
| `scenario-basic-values.yaml` | One combined node — the default path, cheapest |
| `scenario-quorum-values.yaml` | Three combined nodes — the quorum actually forming |
| `scenario-controller-only-values.yaml` | Three controllers, no broker — role-driven generation |
| `scenario-jaas-values.yaml` | SASL listener with an injected JAAS file |
| `scenario-static-quorum-values.yaml` | `mode: static` and ephemeral storage |

A broker-only release is deliberately absent: it cannot reach readiness without the controllers of
another release, and `ct` installs each scenario on its own.
