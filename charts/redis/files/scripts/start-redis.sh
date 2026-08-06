#!/bin/bash
# =============================================================================
# Entrypoint of the Redis container
# =============================================================================
#
# Does three things and gets out of the way:
#
#   1. copies the assembled configuration off its read-only ConfigMap mount onto
#      a writable volume;
#   2. appends the handful of directives that cannot be known before the pod
#      exists — its own DNS name, the data directory, the password, and in
#      sentinel mode which instance to follow;
#   3. hands over to the image's own entrypoint.
#
# That last step matters. `docker-entrypoint.sh` is not a formality: it loads
# the modules bundled with the 8.x image (query engine, JSON, time series,
# probabilistic types) and drops privileges when the container runs as root.
# Bypassing it silently produces a Redis missing half of what the image ships.
#
# Everything here comes from the environment, set by the chart in the pod spec.
# No templating: what you read is what runs.
# =============================================================================
set -euo pipefail

# Both on stderr, never stdout. find_master() returns its answer by echoing it,
# and a command substitution captures every byte the function writes to stdout —
# a log line landing there ends up inside a `replicaof` directive.
log() { echo "redis-start: $*" >&2; }
die() { echo "redis-start: $*" >&2; exit 1; }

: "${POD_NAME:?}" "${POD_NAMESPACE:?}" "${FULLNAME:?}" "${HEADLESS_SERVICE:?}"
: "${CLUSTER_DOMAIN:?}" "${REDIS_MODE:?}" "${REDIS_PORT:?}" "${REPLICA_COUNT:?}"
: "${DATA_DIR:?}" "${CONFIG_DIR:?}" "${MOUNTED_CONFIG_DIR:?}"

ORDINAL="${POD_NAME##*-}"
POD_FQDN="${POD_NAME}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
CONF="${CONFIG_DIR}/redis.conf"
# Where the sidecar sentinel keeps the topology it has learned. On the data
# volume on purpose — see start-sentinel.sh.
SENTINEL_STATE="${DATA_DIR}/sentinel-state.conf"

peer_fqdn() {
  echo "${FULLNAME}-${1}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
}

# A hostname and a port that Redis will accept on a `replicaof` line.
valid_endpoint() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  case "$1" in ''|*[!a-zA-Z0-9.-]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

# The password, if there is one. Read from a file mounted out of a Secret, so it
# never reaches a ConfigMap, an argument or the process table.
PASSWORD=""
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -f "${REDIS_PASSWORD_FILE}" ]; then
  PASSWORD="$(cat "${REDIS_PASSWORD_FILE}")"
fi

# Redis parses a quoted string with backslash escapes, so a password containing
# a quote or a space survives the round trip.
quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# -----------------------------------------------------------------------------
# Sentinel mode: who is the master?
# -----------------------------------------------------------------------------
#
# Redis has no memory of this. A replica is told to follow a master at runtime,
# by sentinel, and forgets it the moment it restarts — so every pod has to work
# the answer out again on every start. Getting it wrong is not a small mistake:
# two instances that both believe they are the master accept writes that one of
# them will later discard.
#
# Three sources, in order of authority.
find_master() {
  local i peer out host port

  # 1. A live sentinel. This is the authority: sentinel is what decides who
  #    leads, and it is the only party that knows about a failover that
  #    happened while this pod was down.
  #
  #    Every sentinel is asked, not just the first one to answer, and an answer
  #    naming someone else is preferred over an answer naming us. A failover
  #    takes a few seconds to propagate, so a sentinel can still be naming the
  #    pod that just died — which, when that pod is this one, is precisely the
  #    answer that would bring a second master back up. The rule is one-way: it
  #    can only ever move us off the master role, never onto it.
  local self_host="" self_port=""
  for (( i = 0; i < REPLICA_COUNT; i++ )); do
    peer="$(peer_fqdn "$i")"
    # `env -u REDISCLI_AUTH`: this container carries the Redis password so that
    # redis-cli can reach the server, and sentinel does not use it. Sending AUTH
    # to a sentinel that never asked for one is an error, and the answer would
    # be lost with it.
    out="$(timeout 3 env -u REDISCLI_AUTH redis-cli -h "${peer}" -p "${SENTINEL_PORT}" -t 2 \
             sentinel get-master-addr-by-name "${SENTINEL_MASTER_SET}" 2>/dev/null)" || continue
    host="$(echo "${out}" | sed -n 1p | tr -d '\r')"
    port="$(echo "${out}" | sed -n 2p | tr -d '\r')"
    valid_endpoint "${host}" "${port}" || continue

    if [ "${host}" != "${POD_FQDN}" ]; then
      log "master is ${host}:${port}, according to the sentinel on ${peer}"
      echo "${host} ${port}"
      return 0
    fi
    # Remembered, and used only if no sentinel names anyone else.
    self_host="${host}"; self_port="${port}"
  done

  if [ -n "${self_host}" ]; then
    log "every sentinel that answered names this pod as the master"
    echo "${self_host} ${self_port}"
    return 0
  fi

  # 2. What our own sentinel wrote down before the restart. This covers the case
  #    that source 1 cannot: everything went down at once, so no sentinel is up
  #    to be asked, and without this every pod would fall through to rule 3 and
  #    make pod 0 the master — discarding whatever the real master held that pod
  #    0 had not yet received.
  if [ -f "${SENTINEL_STATE}" ]; then
    out="$(grep -E "^sentinel monitor ${SENTINEL_MASTER_SET} " "${SENTINEL_STATE}" | tail -n 1 || true)"
    if [ -n "${out}" ]; then
      host="$(echo "${out}" | awk '{print $4}')"
      port="$(echo "${out}" | awk '{print $5}')"
      # Checked rather than trusted. Whatever comes out of this file is about to
      # be written into a `replicaof` directive, and Redis refuses to start on a
      # malformed one — turning a stale file into a pod that never comes back.
      if valid_endpoint "${host}" "${port}"; then
        log "no sentinel answered; the last known master was ${host}:${port}"
        echo "${host} ${port}"
        return 0
      fi
      log "ignoring the master recorded in ${SENTINEL_STATE}: '${host}:${port}' is not a usable endpoint"
    fi
  fi

  # 3. Nothing is known, which is what a first install looks like. Pod 0 leads
  #    and the others follow it. Any other tie-break would need agreement, and
  #    there is nobody to agree with yet.
  log "nothing knows of a master yet; pod 0 takes the role"
  echo "$(peer_fqdn 0) ${REDIS_PORT}"
}

# -----------------------------------------------------------------------------
# Assemble the configuration
# -----------------------------------------------------------------------------
#
# The master is resolved before the file is opened, not while writing into it:
# it takes several network round trips, and a function called inside a redirect
# has every byte it prints appended to the file.
MASTER_HOST=""
MASTER_PORT=""
if [ "${REDIS_MODE}" = "sentinel" ]; then
  read -r MASTER_HOST MASTER_PORT <<< "$(find_master)"
  valid_endpoint "${MASTER_HOST}" "${MASTER_PORT}" \
    || die "refusing to start: '${MASTER_HOST}:${MASTER_PORT}' is not a usable master endpoint"
fi

mkdir -p "${CONFIG_DIR}"
cp "${MOUNTED_CONFIG_DIR}/redis.conf" "${CONF}"
chmod 0600 "${CONF}"

{
  echo ""
  echo "# ==========================================================="
  echo "# Written by the Helm chart at pod startup."
  echo "# Appended last, so every directive below wins over the file."
  echo "# ==========================================================="

  # Where the data goes. The RDB, the AOF and — in cluster mode — nodes.conf all
  # land here, which is the volume.
  echo "dir ${DATA_DIR}"

  # Kept in step with the container port and the service by construction.
  echo "port ${REDIS_PORT}"

  if [ -n "${PASSWORD}" ]; then
    echo "requirepass $(quote "${PASSWORD}")"
    # A replica authenticates to its master with this one. Without it,
    # replication of a password-protected master fails and says little about why.
    echo "masterauth $(quote "${PASSWORD}")"
  fi

  case "${REDIS_MODE}" in
    cluster)
      echo "cluster-enabled yes"
      # On the volume, next to the data. This file is the node's identity — its
      # ID, its slots, its view of its peers. A pod that loses it does not
      # rejoin the cluster, it shows up as a stranger.
      echo "cluster-config-file ${DATA_DIR}/nodes.conf"
      # The address other nodes will hand to clients on a redirect. A pod IP
      # would be wrong the moment this pod is rescheduled; this name is not.
      echo "cluster-announce-hostname ${POD_FQDN}"
      # Cosmetic, and worth the line: it puts the pod name in CLUSTER NODES and
      # in the logs of every other node.
      echo "cluster-announce-human-nodename ${POD_NAME}"
      ;;
    sentinel)
      # Same reasoning: sentinel finds the replicas of a master by reading the
      # addresses they announced to it.
      echo "replica-announce-ip ${POD_FQDN}"
      echo "replica-announce-port ${REDIS_PORT}"

      if [ "${MASTER_HOST}" = "${POD_FQDN}" ]; then
        log "this pod is the master"
      else
        log "following ${MASTER_HOST}:${MASTER_PORT}"
        echo "replicaof ${MASTER_HOST} ${MASTER_PORT}"
      fi
      ;;
    *)
      die "unknown REDIS_MODE '${REDIS_MODE}'"
      ;;
  esac
} >> "${CONF}"

log "configuration written to ${CONF}"

# -----------------------------------------------------------------------------
# Hand over
# -----------------------------------------------------------------------------
exec /usr/local/bin/docker-entrypoint.sh redis-server "${CONF}"
