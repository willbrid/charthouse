#!/bin/bash
# =============================================================================
# One-time bootstrap of the Redis Cluster
# =============================================================================
#
# Redis nodes do not form a cluster by themselves. Started with
# `cluster-enabled yes` they each come up as a cluster of one, owning no slots
# and knowing nobody, and they will wait there indefinitely. Something has to
# hand out the 16384 slots and pair each replica with a master exactly once, and
# that something is this job.
#
# It is idempotent by design — it inspects the cluster before touching it and
# exits when the slots are already assigned — because it runs as a Helm hook on
# every install AND every upgrade, and because a job that is only safe to run
# once is a job that will eventually be run twice.
#
# Everything here comes from the environment, set by the chart in the pod spec.
# =============================================================================
set -euo pipefail

log() { echo "cluster-init: $*"; }
die() { echo "cluster-init: $*" >&2; exit 1; }

: "${FULLNAME:?}" "${HEADLESS_SERVICE:?}" "${POD_NAMESPACE:?}" "${CLUSTER_DOMAIN:?}"
: "${REDIS_PORT:?}" "${REPLICA_COUNT:?}" "${CLUSTER_REPLICAS:?}" "${WAIT_TIMEOUT:?}"

peer_fqdn() {
  echo "${FULLNAME}-${1}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
}

NODES=()
for (( i = 0; i < REPLICA_COUNT; i++ )); do
  NODES+=("$(peer_fqdn "$i"):${REDIS_PORT}")
done

cli() { timeout 10 redis-cli -t 5 "$@"; }

# -----------------------------------------------------------------------------
# 1. Wait for every node
# -----------------------------------------------------------------------------
#
# The hook starts while the StatefulSet is still coming up, so this is expected
# to wait. Every node has to be there: `--cluster create` takes the full set at
# once and cannot be given the rest later.
log "waiting for ${REPLICA_COUNT} nodes, up to ${WAIT_TIMEOUT}s"

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
for node in "${NODES[@]}"; do
  host="${node%:*}"
  until [ "$(cli -h "${host}" -p "${REDIS_PORT}" ping 2>/dev/null)" = "PONG" ]; do
    [ "$(date +%s)" -lt "${deadline}" ] || die "timed out waiting for ${host}. Check the pods: kubectl get pods -l app.kubernetes.io/instance=${FULLNAME}"
    sleep 5
  done

  # Answering PING is not enough — a node started without cluster-enabled looks
  # perfectly healthy and cannot be part of a cluster. Catching it here beats
  # letting redis-cli fail halfway through creating one.
  enabled="$(cli -h "${host}" -p "${REDIS_PORT}" info cluster 2>/dev/null | grep '^cluster_enabled:' | cut -d: -f2 | tr -d '[:space:]')"
  [ "${enabled}" = "1" ] || die "${host} is running without cluster support (cluster_enabled=${enabled:-?})"

  log "  ${host} is up"
done

# -----------------------------------------------------------------------------
# 2. Is there already a cluster?
# -----------------------------------------------------------------------------
first="${NODES[0]%:*}"
info="$(cli -h "${first}" -p "${REDIS_PORT}" cluster info 2>/dev/null || true)"
assigned="$(echo "${info}" | grep '^cluster_slots_assigned:' | cut -d: -f2 | tr -d '[:space:]')"
known="$(echo "${info}" | grep '^cluster_known_nodes:' | cut -d: -f2 | tr -d '[:space:]')"

if [ "${assigned:-0}" = "16384" ]; then
  log "the cluster already owns all 16384 slots across ${known} nodes — nothing to do"

  # Worth saying out loud on an upgrade that added pods: this job creates a
  # cluster, it does not grow one. Adding a shard means adding the nodes and
  # moving slots onto them, which moves data and cannot be done blindly.
  if [ "${known:-0}" -lt "${REPLICA_COUNT}" ]; then
    log ""
    log "NOTE: ${REPLICA_COUNT} pods are running but the cluster only knows ${known} nodes."
    log "      The new ones are up and idle: they hold no slots and no client will"
    log "      ever be redirected to them. Adding them means resharding, which"
    log "      moves data and is deliberately left to you:"
    log ""
    log "        redis-cli --cluster add-node <new-node>:${REDIS_PORT} ${first}:${REDIS_PORT}"
    log "        redis-cli --cluster rebalance ${first}:${REDIS_PORT} --cluster-use-empty-masters"
    log ""
  fi
  exit 0
fi

if [ "${known:-1}" -gt 1 ]; then
  die "the nodes know each other (${known} known) but only ${assigned:-0} slots are assigned. That is a half-formed cluster, and creating one over it would make things worse. Inspect it with: redis-cli --cluster check ${first}:${REDIS_PORT}"
fi

# -----------------------------------------------------------------------------
# 3. Create it
# -----------------------------------------------------------------------------
log "creating a cluster of ${REPLICA_COUNT} nodes, ${CLUSTER_REPLICAS} replica(s) per master"
log "  nodes: ${NODES[*]}"

# --cluster-yes answers the interactive confirmation, which has nobody to answer
# it here. redis-cli works out the master/replica pairing itself and spreads the
# replicas away from their master where the addresses let it.
redis-cli --cluster create "${NODES[@]}" \
  --cluster-replicas "${CLUSTER_REPLICAS}" \
  --cluster-yes

# -----------------------------------------------------------------------------
# 4. Check what was built
# -----------------------------------------------------------------------------
#
# `--cluster create` returning 0 means the commands were accepted, not that the
# cluster converged: the nodes still have to agree with each other through
# gossip. Waiting for that here is what makes `helm install --wait` mean
# something.
log "waiting for every node to report cluster_state:ok"

deadline=$(( $(date +%s) + 120 ))
for node in "${NODES[@]}"; do
  host="${node%:*}"
  until [ "$(cli -h "${host}" -p "${REDIS_PORT}" cluster info 2>/dev/null | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')" = "ok" ]; do
    [ "$(date +%s)" -lt "${deadline}" ] || die "${host} never reached cluster_state:ok. Inspect it with: redis-cli --cluster check ${first}:${REDIS_PORT}"
    sleep 3
  done
done

log "cluster is up:"
cli -h "${first}" -p "${REDIS_PORT}" cluster info | grep -E '^cluster_(state|slots_assigned|known_nodes|size):'
