# Per-application users and TLS

A shared `requirepass` gives every client the same, complete access. ACLs give each application its
own user, its own key prefix and its own command set. This scenario adds both: an ACL file injected
through `extraFiles`, and TLS on the Redis port.

## Values

```yaml
# values-acl-tls.yaml
mode: sentinel
replicaCount: 3

image:
  repository: redis
  tag: "8.2.8"

sentinel:
  masterSet: mymaster

auth:
  enabled: true
  # Referenced from the ACL file below through `tpl`, so it is written once.
  # For a real deployment use existingSecret and drop this line entirely.
  password: "change-me-please"
  # existingSecret: redis-credentials
  # existingSecretPasswordKey: password

extraFiles:
  mountPath: /etc/redis/files

  configMap:
    # The `default` line is NOT optional. Loading an ACL file replaces the whole
    # user list, `default` included — a file that stays silent about it hands
    # the default user back its built-in `nopass` definition, discarding
    # requirepass. Everything then starts and nothing replicates: the replicas
    # fail with "AUTH called without any password configured for the default
    # user".
    users.acl: |
      user default on >{{ .Values.auth.password }} ~* &* +@all

      # Read and write its own keys, nothing else. No admin commands, no
      # FLUSHDB, no access to another application's prefix.
      user orders on >orders-secret ~orders:* &orders:* +@read +@write +@list +@hash -@dangerous

      # Read-only, for a reporting job.
      user analytics on >analytics-secret ~orders:* +@read -@dangerous

      # A monitoring exporter needs INFO and little else.
      user exporter on >exporter-secret ~ +client|info +info +ping +latency +slowlog

  secret:
    # TLS material, in a Secret rather than a ConfigMap. Same mount path.
    # In practice these come from cert-manager — see the note at the end.
    tls.crt: |
      -----BEGIN CERTIFICATE-----
      REPLACE-ME
      -----END CERTIFICATE-----
    tls.key: |
      -----BEGIN PRIVATE KEY-----
      REPLACE-ME
      -----END PRIVATE KEY-----
    ca.crt: |
      -----BEGIN CERTIFICATE-----
      REPLACE-ME
      -----END CERTIFICATE-----

  # Read by uid 999 through fsGroup, not by the owner.
  defaultMode: 0440

config:
  overrides:
    # Point Redis at the injected file, by the path it is mounted at.
    aclfile: /etc/redis/files/users.acl

    # TLS on its own port, with the plain port left open for the probes and for
    # in-cluster clients that do not speak TLS yet. Set `port: 0` once every
    # client has moved, and replace the probe commands with TLS-aware ones.
    tls-port: 6380
    tls-cert-file: /etc/redis/files/tls.crt
    tls-key-file: /etc/redis/files/tls.key
    tls-ca-cert-file: /etc/redis/files/ca.crt
    # Replication and sentinel traffic over TLS too — otherwise the replicas
    # keep talking in the clear and the exercise is decorative.
    tls-replication: "yes"
    tls-auth-clients: "no"

    maxmemory: 2gb
    maxmemory-policy: noeviction

  sentinelOverrides:
    tls-port: 26380
    tls-cert-file: /etc/redis/files/tls.crt
    tls-key-file: /etc/redis/files/tls.key
    tls-ca-cert-file: /etc/redis/files/ca.crt
    tls-replication: "yes"

persistence:
  enabled: true
  size: 20Gi

resources:
  requests:
    cpu: 500m
    memory: 3Gi
  limits:
    memory: 3Gi
```

## Install

The certificate normally comes from cert-manager rather than from the values file. Point the chart
at real files instead of inlining them:

```bash
helm install redis oci://ghcr.io/willbrid/charts/redis \
  --version 0.1.0 \
  --namespace redis --create-namespace \
  --values values-acl-tls.yaml \
  --set-file extraFiles.secret.tls\\.crt=./tls.crt \
  --set-file extraFiles.secret.tls\\.key=./tls.key \
  --set-file extraFiles.secret.ca\\.crt=./ca.crt
```

Repeat the `--set-file` flags on every `helm upgrade` — an upgrade that omits them drops the files.

## Verify

```bash
# the users Redis actually loaded
kubectl -n redis exec redis-0 -- redis-cli -a "change-me-please" acl list
kubectl -n redis exec redis-0 -- redis-cli -a "change-me-please" acl whoami

# the orders user can write its own prefix …
kubectl -n redis exec redis-0 -- \
  redis-cli --user orders --pass orders-secret set orders:1 ok

# … and nothing else
kubectl -n redis exec redis-0 -- \
  redis-cli --user orders --pass orders-secret set billing:1 nope
# (error) NOPERM ... no permissions to access one of the keys

kubectl -n redis exec redis-0 -- \
  redis-cli --user orders --pass orders-secret flushall
# (error) NOPERM ... has no permissions to run the 'flushall' command

# TLS answering on its own port
kubectl -n redis exec redis-0 -- \
  redis-cli --tls --cert /etc/redis/files/tls.crt \
            --key /etc/redis/files/tls.key \
            --cacert /etc/redis/files/ca.crt \
            -p 6380 -a "change-me-please" ping
```

## What to know

- **The `default` user line is the trap.** Everything starts, the master accepts commands, and
  replication is silently broken — because the replicas authenticate as `default` with the password
  `requirepass` set, and the ACL file just replaced that definition. Always define `default`
  explicitly with the same password.
- **`ACL SETUSER` at runtime does not survive a restart** unless you also `ACL SAVE`, which writes
  back to `aclfile` — a file mounted read-only from a ConfigMap here. Manage users through the values
  file and roll the release, not through the CLI.
- **The certificate must cover the per-pod DNS names**, `redis-0.redis-headless.redis.svc.cluster.local`
  and siblings, since that is what replication and sentinel dial. A wildcard on
  `*.redis-headless.redis.svc.cluster.local` is the usual answer.
- **Keeping the plain port open is deliberate here.** The chart's probes run `redis-cli` without TLS;
  setting `port: 0` without replacing `livenessProbe.command` and `readinessProbe.command` leaves
  every pod failing its probes. Migrate clients first, then close the port and the probes together.
- **`tls-auth-clients: "no"` means the server does not require client certificates.** Set it to
  `yes` for mutual TLS, and give every client a certificate signed by the same CA — including the
  sentinels.
- **The password still appears in this values file.** For anything real, use `auth.existingSecret`
  and let an external secret manager own it. The per-user ACL passwords deserve the same treatment,
  through `extraFiles.secret` rather than `configMap`.
