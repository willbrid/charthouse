# Authenticated and encrypted client traffic

`SASL_SSL` on the client listener: applications authenticate with a username and password, and the
connection is encrypted. Replication between brokers stays on the separate `INTERNAL` listener,
which is the reason to declare two in the first place — tightening one does not disturb the other.

Two ingredients beyond the values: a **JAAS file** referenced from `KAFKA_OPTS`, and the **keystore
and truststore** the `apache/kafka` image reads from `/etc/kafka/secrets`.

## Preparing the keystores

The image expects JKS files. Produce them from a certificate you already have:

```bash
# server keystore, from a PEM certificate and key
openssl pkcs12 -export \
  -in tls.crt -inkey tls.key -name kafka \
  -out kafka.p12 -password pass:changeit
keytool -importkeystore \
  -srckeystore kafka.p12 -srcstoretype PKCS12 -srcstorepass changeit \
  -destkeystore kafka.keystore.jks -deststorepass changeit

# truststore, holding the CA that signed it
keytool -import -noprompt -alias ca \
  -file ca.crt -keystore kafka.truststore.jks -storepass changeit
```

The certificate must cover the names clients dial — the per-pod DNS names of the headless service,
`*.kafka-headless.kafka.svc.cluster.local`, plus any external hostname.

## Values

```yaml
# values-secure.yaml
replicaCount: 3

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
    # Replication traffic. Left plaintext here so one thing changes at a time;
    # move it to SSL once the client listener works.
    - name: INTERNAL
      port: 9092
      securityProtocol: PLAINTEXT
    # Applications: authenticated and encrypted.
    - name: CLIENT
      port: 9094
      securityProtocol: SASL_SSL
  interBrokerListenerName: "INTERNAL"

# Files whose names you choose, mounted read-only. extraFiles.mountPath defaults
# to /etc/kafka/secrets, which is also where the apache/kafka image derives its
# SSL file paths from.
extraFiles:
  mountPath: /etc/kafka/secrets
  secret:
    # SCRAM would be better — credentials live in the cluster metadata rather
    # than in a file — but PLAIN keeps this example to one moving part. See the
    # note at the end.
    kafka_jaas.conf: |
      KafkaServer {
        org.apache.kafka.common.security.plain.PlainLoginModule required
        username="admin"
        password="admin-secret"
        user_admin="admin-secret"
        user_orders="orders-secret"
        user_billing="billing-secret";
      };

extraEnv:
  # Not a Kafka property, so it belongs here rather than in `config`. The image
  # refuses to start a broker with a SASL listener whose KAFKA_OPTS carries no
  # java.security.auth.login.config.
  - name: KAFKA_OPTS
    value: "-Djava.security.auth.login.config=/etc/kafka/secrets/kafka_jaas.conf"
  - name: KAFKA_HEAP_OPTS
    value: "-Xms4g -Xmx4g"

# Passwords go through the Secret, not into `config` — anything in `config`
# becomes a plain-text environment variable from a ConfigMap.
secret:
  KAFKA_SSL_KEYSTORE_PASSWORD: "changeit"
  KAFKA_SSL_KEY_PASSWORD: "changeit"
  KAFKA_SSL_TRUSTSTORE_PASSWORD: "changeit"

config:
  # SASL. The per-listener form is what restricts PLAIN to the CLIENT listener.
  sasl.enabled.mechanisms: PLAIN
  listener.name.client.sasl.enabled.mechanisms: PLAIN

  # SSL material. The file names are relative to /etc/kafka/secrets.
  ssl.keystore.location: /etc/kafka/secrets/kafka.keystore.jks
  ssl.keystore.type: JKS
  ssl.truststore.location: /etc/kafka/secrets/kafka.truststore.jks
  ssl.truststore.type: JKS
  # Empty means "do not verify the hostname", which is the default and is wrong
  # for anything reachable beyond the pod network. https enables verification.
  ssl.endpoint.identification.algorithm: https
  ssl.client.auth: none

  # Without an authorizer, an authenticated client can do anything. With one,
  # give the admin principal super-user rights or you lock yourself out.
  authorizer.class.name: org.apache.kafka.metadata.authorizer.StandardAuthorizer
  super.users: "User:admin"
  allow.everyone.if.no.acl.found: false

  offsets.topic.replication.factor: 3
  transaction.state.log.replication.factor: 3
  transaction.state.log.min.isr: 2
  default.replication.factor: 3
  min.insync.replicas: 2
  num.partitions: 6
  auto.create.topics.enable: false

persistence:
  enabled: true
  size: 500Gi
  storageClassName: fast-ssd

statefulSet:
  podManagementPolicy: Parallel
  terminationGracePeriodSeconds: 300

podDisruptionBudget:
  enabled: true
  maxUnavailable: 1

resources:
  requests:
    cpu: "2"
    memory: 16Gi
  limits:
    cpu: "4"
    memory: 16Gi
```

## Install

The keystores are binary, so they go in with `--set-file` rather than inline:

```bash
helm install kafka oci://ghcr.io/willbrid/charts/kafka \
  --version 0.1.0 \
  --namespace kafka --create-namespace \
  --values values-secure.yaml \
  --set-file extraFiles.secret.kafka\\.keystore\\.jks=./kafka.keystore.jks \
  --set-file extraFiles.secret.kafka\\.truststore\\.jks=./kafka.truststore.jks
```

Repeat both `--set-file` flags on every `helm upgrade` — an upgrade that omits them drops the files
and the brokers fail to start.

## Connect as a client

```properties
# client.properties
security.protocol=SASL_SSL
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required \
  username="orders" password="orders-secret";
ssl.truststore.location=/path/to/kafka.truststore.jks
ssl.truststore.password=changeit
ssl.endpoint.identification.algorithm=https
```

```bash
kafka-topics.sh --bootstrap-server kafka.kafka.svc.cluster.local:9094 \
  --command-config client.properties --list

# grant the orders principal what it needs
kafka-acls.sh --bootstrap-server kafka.kafka.svc.cluster.local:9094 \
  --command-config admin.properties \
  --add --allow-principal User:orders \
  --operation Read --operation Write --operation Describe --topic orders
```

## What to know

- **`helm test` is not rendered when no listener accepts an unauthenticated client**, because it
  would then fail for reasons unrelated to the cluster's health. Keeping `INTERNAL` on `PLAINTEXT`,
  as above, keeps the test working. Set `tests.enabled: false` once you secure that one too.
- **`ssl.endpoint.identification.algorithm` is empty by default**, meaning no hostname verification:
  encryption without authentication of the server. Set it to `https` on both sides, and make the
  certificate cover the per-pod names the brokers advertise.
- **Turning on the authorizer without `super.users` locks you out.** The first thing to verify after
  install is that the admin principal can still list topics.
- **PLAIN puts every password in a file on disk.** SCRAM keeps them in the cluster metadata instead:
  seed the first credential at format time with
  `kraft.format.extraArgs: ["--add-scram", "SCRAM-SHA-512=[name=admin,password=changeme]"]`, set
  `sasl.enabled.mechanisms: SCRAM-SHA-512`, and manage the rest with `kafka-configs.sh`. That is the
  better end state; PLAIN is the shorter path to a working listener.
- **Changing a file rolls the StatefulSet**, since the pods carry a checksum of it. Certificate
  renewal is therefore a rolling restart, not a live reload — plan it like any other rollout.
- **Securing `INTERNAL` too** means moving it to `SSL` and adding the inter-broker credentials to
  the JAAS file under `KafkaClient`. Do it as a second step, after clients work.
