#!/bin/bash
# =============================================================================
# Entrypoint of the Redis Sentinel sidecar
# =============================================================================
#
# Sentinel's configuration file is not read-only scripture the way a server's
# is: sentinel REWRITES it as it learns the topology — which instance leads,
# which replicas follow, which other sentinels it has met. That rewrite is the
# only durable record of a failover that ever existed.
#
# So the file lives on the data volume rather than on a scratch emptyDir, and
# the two halves of it are kept apart:
#
#   - the declarative half comes from the ConfigMap on every start, so a change
#     to files/sentinel.conf actually reaches the sentinels;
#   - the learned half — who the master is — is read back out of the previous
#     rewrite, so a pod that restarts does not forget a failover that happened
#     while it was gone.
#
# Everything here comes from the environment, set by the chart in the pod spec.
# =============================================================================
set -euo pipefail

# On stderr, never stdout: find_master() returns its answer by echoing it, and a
# command substitution captures everything the function writes to stdout.
log() { echo "sentinel-start: $*" >&2; }

: "${POD_NAME:?}" "${POD_NAMESPACE:?}" "${FULLNAME:?}" "${HEADLESS_SERVICE:?}"
: "${CLUSTER_DOMAIN:?}" "${REDIS_PORT:?}" "${SENTINEL_PORT:?}" "${REPLICA_COUNT:?}"
: "${SENTINEL_MASTER_SET:?}" "${SENTINEL_QUORUM:?}"
: "${DATA_DIR:?}" "${MOUNTED_CONFIG_DIR:?}"

POD_FQDN="${POD_NAME}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
# The file sentinel is started with, and the one it rewrites. Not a copy — this
# is the live config.
CONF="${DATA_DIR}/sentinel-state.conf"

peer_fqdn() {
  echo "${FULLNAME}-${1}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
}

# A hostname and a port that sentinel will accept on a `monitor` line. Anything
# else makes it refuse to start, and a stale file would then keep the pod down.
valid_endpoint() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  case "$1" in ''|*[!a-zA-Z0-9.-]*) return 1 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

PASSWORD=""
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -f "${REDIS_PASSWORD_FILE}" ]; then
  PASSWORD="$(cat "${REDIS_PASSWORD_FILE}")"
fi

quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

# -----------------------------------------------------------------------------
# Which master to monitor
# -----------------------------------------------------------------------------
#
# Same question the server side asks, answered from the same three sources and
# in the same order — a live sentinel first, our own last rewrite second, pod 0
# as the tie-break of last resort. The two must agree, or a pod would replicate
# from one instance while its sentinel watched another.
find_master() {
  local i peer out host port

  for (( i = 0; i < REPLICA_COUNT; i++ )); do
    peer="$(peer_fqdn "$i")"
    [ "${peer}" = "${POD_FQDN}" ] && continue
    out="$(timeout 3 redis-cli -h "${peer}" -p "${SENTINEL_PORT}" -t 2 \
             sentinel get-master-addr-by-name "${SENTINEL_MASTER_SET}" 2>/dev/null)" || continue
    host="$(echo "${out}" | sed -n 1p | tr -d '\r')"
    port="$(echo "${out}" | sed -n 2p | tr -d '\r')"
    if [ -n "${host}" ] && [ -n "${port}" ]; then
      log "master is ${host}:${port}, according to the sentinel on ${peer}"
      echo "${host} ${port}"
      return 0
    fi
  done

  if [ -f "${CONF}" ]; then
    out="$(grep -E "^sentinel monitor ${SENTINEL_MASTER_SET} " "${CONF}" | tail -n 1 || true)"
    if [ -n "${out}" ]; then
      host="$(echo "${out}" | awk '{print $4}')"
      port="$(echo "${out}" | awk '{print $5}')"
      if valid_endpoint "${host}" "${port}"; then
        log "no sentinel answered; keeping the master from our last rewrite, ${host}:${port}"
        echo "${host} ${port}"
        return 0
      fi
      log "ignoring the master recorded in ${CONF}: '${host}:${port}' is not a usable endpoint"
    fi
  fi

  log "nothing knows of a master yet; monitoring pod 0"
  echo "$(peer_fqdn 0) ${REDIS_PORT}"
}

read -r MASTER_HOST MASTER_PORT <<< "$(find_master)"
valid_endpoint "${MASTER_HOST}" "${MASTER_PORT}" \
  || { echo "sentinel-start: refusing to start: '${MASTER_HOST}:${MASTER_PORT}' is not a usable master endpoint" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Assemble the configuration
# -----------------------------------------------------------------------------
#
# The monitor line comes FIRST and the file from the ConfigMap after it. Not a
# style choice: every `sentinel <directive> <master-name>` line is rejected —
# "No such master with specified name" — unless the master has already been
# declared. Everything in files/sentinel.conf names the master, so nothing in it
# can precede the declaration.
TMP="$(mktemp "${DATA_DIR}/.sentinel-state.XXXXXX")"

{
  echo "# ==========================================================="
  echo "# Written by the Helm chart at pod startup, then rewritten by"
  echo "# sentinel itself as it learns the topology. Do not edit: the"
  echo "# declarative part comes from the chart's ConfigMap and is"
  echo "# regenerated here on every start."
  echo "# ==========================================================="
  echo "port ${SENTINEL_PORT}"
  echo "dir ${DATA_DIR}"

  # What this sentinel calls itself when talking to the others and to clients.
  # A pod IP here is an address that outlives neither a reschedule nor a rolling
  # update, and the sentinels would go on gossiping it long after it moved.
  echo "sentinel announce-ip ${POD_FQDN}"
  echo "sentinel announce-port ${SENTINEL_PORT}"

  echo "sentinel monitor ${SENTINEL_MASTER_SET} ${MASTER_HOST} ${MASTER_PORT} ${SENTINEL_QUORUM}"

  if [ -n "${PASSWORD}" ]; then
    # How sentinel authenticates to the instances it monitors. Without it, a
    # password-protected master is reported down by every sentinel at once, and
    # they fail over to a replica they cannot reach either.
    echo "sentinel auth-pass ${SENTINEL_MASTER_SET} $(quote "${PASSWORD}")"
  fi

  echo ""
  cat "${MOUNTED_CONFIG_DIR}/sentinel.conf"
} > "${TMP}"

chmod 0600 "${TMP}"
mv -f "${TMP}" "${CONF}"

log "configuration written to ${CONF}"

exec /usr/local/bin/docker-entrypoint.sh redis-sentinel "${CONF}"
