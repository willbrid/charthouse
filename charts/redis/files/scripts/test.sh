#!/bin/bash
# =============================================================================
# `helm test` — did the topology the chart described actually come to be?
# =============================================================================
#
# Pod readiness cannot answer that, and the gap is the whole reason this script
# exists. Redis instances that never formed a cluster are perfectly healthy
# instances: they start, they answer PING, they pass every probe. So are
# replicas that never found their master. In both cases every pod is Ready, the
# install reports success, and what you have is not what you asked for.
#
# So this checks the shape of the thing — all 16384 slots assigned across the
# expected number of masters, or a master with the expected number of replicas
# behind it — and then writes a key and reads it back, which is the only proof
# that the shape is also usable.
#
# Everything here comes from the environment, set by the chart in the pod spec.
# =============================================================================
set -uo pipefail

: "${FULLNAME:?}" "${HEADLESS_SERVICE:?}" "${POD_NAMESPACE:?}" "${CLUSTER_DOMAIN:?}"
: "${REDIS_PORT:?}" "${REPLICA_COUNT:?}" "${REDIS_MODE:?}"

failures=0

ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; failures=$(( failures + 1 )); }
head() { echo ""; echo "==> $*"; }

peer_fqdn() {
  echo "${FULLNAME}-${1}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
}

cli() { timeout 15 redis-cli -t 5 "$@"; }
# Sentinel has no password of its own, so the one this pod carries must not be
# sent to it.
scli() { timeout 15 env -u REDISCLI_AUTH redis-cli -t 5 "$@"; }

field() { echo "$1" | grep "^$2:" | cut -d: -f2 | tr -d '[:space:]'; }

case "${REDIS_MODE}" in

# -----------------------------------------------------------------------------
cluster)
# -----------------------------------------------------------------------------
  : "${EXPECTED_MASTERS:?}"

  head "cluster state, node by node"
  for (( i = 0; i < REPLICA_COUNT; i++ )); do
    host="$(peer_fqdn "$i")"
    info="$(cli -h "${host}" -p "${REDIS_PORT}" cluster info 2>/dev/null)"
    if [ -z "${info}" ]; then
      bad "${host} did not answer CLUSTER INFO"
      continue
    fi

    state="$(field "${info}" cluster_state)"
    slots="$(field "${info}" cluster_slots_assigned)"
    known="$(field "${info}" cluster_known_nodes)"
    size="$(field "${info}" cluster_size)"

    # All four, on every node. A node can be `ok` while disagreeing with its
    # peers about who exists — that is a split view, and it is exactly the
    # failure that hides behind a set of green pods.
    [ "${state}" = "ok" ]                     || bad "${host}: cluster_state is '${state}'"
    [ "${slots}" = "16384" ]                  || bad "${host}: ${slots}/16384 slots assigned"
    [ "${known}" = "${REPLICA_COUNT}" ]       || bad "${host}: knows ${known} nodes, expected ${REPLICA_COUNT}"
    [ "${size}" = "${EXPECTED_MASTERS}" ]     || bad "${host}: cluster_size is ${size}, expected ${EXPECTED_MASTERS}"
    [ "${state}" = "ok" ] && [ "${slots}" = "16384" ] && [ "${known}" = "${REPLICA_COUNT}" ] && [ "${size}" = "${EXPECTED_MASTERS}" ] \
      && ok "${host}: state=ok slots=16384 nodes=${known} size=${size}"
  done

  head "the addresses handed to clients"
  # The check is made on a real MOVED redirect, and not on CLUSTER NODES, which
  # would pass either way: the announced hostname appears there as metadata even
  # when what clients are actually given is a pod IP. A redirect is the thing
  # itself — the address a client is told to go to, and the one it caches.
  #
  # Getting this wrong produces a cluster that works right up to the first
  # reschedule, and then sends clients to whatever inherited the address.
  moved=""
  for i in $(seq 0 30); do
    key="helm-test-endpoint-${i}"
    out="$(cli -h "$(peer_fqdn 0)" -p "${REDIS_PORT}" set "${key}" x 2>&1)"
    case "${out}" in
      MOVED*) moved="${out}"; break ;;
      OK)     cli -h "$(peer_fqdn 0)" -p "${REDIS_PORT}" del "${key}" >/dev/null 2>&1 ;;
    esac
  done

  if [ -z "${moved}" ]; then
    bad "no key out of 31 was owned by another node, so no redirect could be inspected"
  else
    # MOVED <slot> <endpoint>:<port>
    endpoint="$(echo "${moved}" | awk '{print $3}')"
    case "${endpoint}" in
      *"${HEADLESS_SERVICE}"*)
        ok "redirects carry DNS names (${endpoint})" ;;
      *)
        bad "redirects carry '${endpoint}', which is a pod address rather than a name."
        echo "        Clients cache it, and a reschedule hands it to something else."
        echo "        Is 'cluster-preferred-endpoint-type hostname' still in the configuration?" ;;
    esac
  fi

  head "write and read back, through the redirects"
  key="helm-test-$(date +%s)"
  # -c follows MOVED, which is what a cluster-aware client does. Without it this
  # would only ever test the node that happens to own the slot.
  if [ "$(cli -c -h "${FULLNAME}" -p "${REDIS_PORT}" set "${key}" ok 2>&1)" = "OK" ]; then
    value="$(cli -c -h "${FULLNAME}" -p "${REDIS_PORT}" get "${key}" 2>&1)"
    [ "${value}" = "ok" ] && ok "wrote and read ${key}" || bad "read back '${value}' instead of 'ok'"
    cli -c -h "${FULLNAME}" -p "${REDIS_PORT}" del "${key}" >/dev/null 2>&1
  else
    bad "could not write through the service"
  fi
  ;;

# -----------------------------------------------------------------------------
sentinel)
# -----------------------------------------------------------------------------
  : "${SENTINEL_PORT:?}" "${SENTINEL_MASTER_SET:?}" "${SENTINEL_QUORUM:?}"

  # Sentinels do not know each other at startup: they find each other through a
  # hello message on the master's pub/sub channel, and that takes tens of
  # seconds. A test running the moment the pods report Ready — which is what
  # `helm install --wait && helm test` does — legitimately sees a set that has
  # not converged yet, and every check below would fail on a cluster that is
  # merely young. So the state is polled until it settles, and only then judged.
  converged() {
    local i out host port peers slaves
    master_host=""; master_port=""

    for (( i = 0; i < REPLICA_COUNT; i++ )); do
      out="$(scli -h "$(peer_fqdn "$i")" -p "${SENTINEL_PORT}" \
               sentinel get-master-addr-by-name "${SENTINEL_MASTER_SET}" 2>/dev/null)"
      host="$(echo "${out}" | sed -n 1p | tr -d '\r')"
      port="$(echo "${out}" | sed -n 2p | tr -d '\r')"
      [ -n "${host}" ] && [ -n "${port}" ] || return 1
      if [ -z "${master_host}" ]; then
        master_host="${host}"; master_port="${port}"
      elif [ "${host}" != "${master_host}" ]; then
        return 1
      fi

      peers="$(scli -h "$(peer_fqdn "$i")" -p "${SENTINEL_PORT}" \
                 sentinel sentinels "${SENTINEL_MASTER_SET}" 2>/dev/null | grep -c '^name$')"
      [ "${peers:-0}" -eq $(( REPLICA_COUNT - 1 )) ] || return 1
    done

    slaves="$(cli -h "${master_host}" -p "${REDIS_PORT}" info replication 2>/dev/null \
                | grep '^connected_slaves:' | cut -d: -f2 | tr -d '[:space:]')"
    [ "${slaves:-0}" -eq $(( REPLICA_COUNT - 1 )) ] || return 1
    return 0
  }

  head "sentinel"
  master_host=""
  master_port=""
  deadline=$(( $(date +%s) + 180 ))
  until converged; do
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "  (gave up waiting for the sentinels to converge; reporting what is there)"
      break
    fi
    sleep 5
  done

  if [ -z "${master_host}" ]; then
    bad "no sentinel could name a master for '${SENTINEL_MASTER_SET}'"
  else
    ok "master is ${master_host}:${master_port}"

    # It must be a name, not an address. A sentinel announcing pod IPs hands
    # clients something that stops being true at the next reschedule.
    case "${master_host}" in
      *"${HEADLESS_SERVICE}"*) ok "announced as a DNS name" ;;
      *) bad "announced as '${master_host}', which is not a per-pod DNS name" ;;
    esac

    # Every sentinel must agree, and each must see the others. A quorum that
    # only half of them are part of is not a quorum, and it fails silently until
    # the day a failover is actually needed.
    for (( i = 0; i < REPLICA_COUNT; i++ )); do
      host="$(peer_fqdn "$i")"
      out="$(scli -h "${host}" -p "${SENTINEL_PORT}" \
               sentinel get-master-addr-by-name "${SENTINEL_MASTER_SET}" 2>/dev/null | sed -n 1p | tr -d '\r')"
      [ "${out}" = "${master_host}" ] || bad "the sentinel on ${host} says the master is '${out:-<nothing>}'"

      peers="$(scli -h "${host}" -p "${SENTINEL_PORT}" sentinel sentinels "${SENTINEL_MASTER_SET}" 2>/dev/null | grep -c '^name$')"
      expected=$(( REPLICA_COUNT - 1 ))
      [ "${peers:-0}" = "${expected}" ] || bad "the sentinel on ${host} sees ${peers:-0} peers, expected ${expected}"
    done
    [ "${failures}" -eq 0 ] && ok "all ${REPLICA_COUNT} sentinels agree and see each other"
  fi

  head "replication"
  repl="$(cli -h "${master_host:-$(peer_fqdn 0)}" -p "${REDIS_PORT}" info replication 2>/dev/null)"
  role="$(field "${repl}" role)"
  connected="$(field "${repl}" connected_slaves)"
  expected=$(( REPLICA_COUNT - 1 ))

  [ "${role}" = "master" ] || bad "the instance sentinel calls the master reports role '${role}'"
  [ "${connected:-0}" = "${expected}" ] \
    && ok "${connected} replica(s) connected" \
    || bad "${connected:-0} replica(s) connected, expected ${expected}"

  head "write to the master, read from a replica"
  key="helm-test-$(date +%s)"
  if [ "$(cli -h "${master_host}" -p "${REDIS_PORT}" set "${key}" ok 2>&1)" = "OK" ]; then
    ok "wrote ${key} to the master"

    # Replication is asynchronous, so a read straight after a write is a race
    # this test has no business losing. A couple of seconds is generous.
    found=0
    for (( i = 0; i < REPLICA_COUNT; i++ )); do
      host="$(peer_fqdn "$i")"
      [ "${host}" = "${master_host}" ] && continue
      for attempt in 1 2 3 4 5; do
        [ "$(cli -h "${host}" -p "${REDIS_PORT}" get "${key}" 2>&1)" = "ok" ] && { found=1; break; }
        sleep 1
      done
      [ "${found}" = "1" ] && { ok "replicated to ${host}"; break; }
    done
    [ "${found}" = "1" ] || bad "the key never reached a replica"

    cli -h "${master_host}" -p "${REDIS_PORT}" del "${key}" >/dev/null 2>&1
  else
    bad "could not write to the master"
  fi
  ;;

*)
  bad "unknown REDIS_MODE '${REDIS_MODE}'"
  ;;
esac

echo ""
if [ "${failures}" -eq 0 ]; then
  echo "==> OK"
  exit 0
fi
echo "==> ${failures} check(s) failed"
exit 1
