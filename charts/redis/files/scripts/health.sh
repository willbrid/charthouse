#!/bin/bash
# =============================================================================
# Probe script — startup, liveness and readiness, for both containers
# =============================================================================
#
#   usage: health.sh <startup|liveness|readiness> [cluster-state] [master-link]
#
# The probe kind is not decoration. The same observation means different things
# to each of the three, and answering all of them the same way is how a chart
# ends up restarting a healthy instance or serving traffic from a broken one:
#
#   startup    "has it finished coming up?"   — an instance loading its dataset
#              has not, and liveness and readiness are held off until this
#              passes, which is what lets them be strict.
#   liveness   "will a restart help?"         — the only question worth asking,
#              because failing it causes one.
#   readiness  "should it get traffic?"       — cheap to fail and reversible.
#
# Extra checks are named as arguments so `kubectl describe pod` shows exactly
# what each probe verifies.
#
# Everything here comes from the environment, set by the chart in the pod spec.
# =============================================================================
set -uo pipefail

KIND="${1:-liveness}"
shift || true

PORT="${HEALTH_PORT:-${REDIS_PORT:?}}"
CLI=(redis-cli -h 127.0.0.1 -p "${PORT}" -t 3)

fail() { echo "health(${KIND}): $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Does it answer at all?
# -----------------------------------------------------------------------------
answer="$(timeout 5 "${CLI[@]}" ping 2>&1)" || true

case "${answer}" in
  PONG)
    ;;
  *LOADING*)
    # Reading the RDB or the AOF back into memory. The process is alive and
    # doing exactly what it should; it just cannot serve yet.
    case "${KIND}" in
      liveness) exit 0 ;;
      *)        fail "still loading the dataset" ;;
    esac
    ;;
  *MASTERDOWN*)
    # A replica whose master is unreachable, with replica-serve-stale-data off.
    # Restarting it would not bring the master back.
    case "${KIND}" in
      liveness) exit 0 ;;
      *)        fail "master is down and stale reads are disabled" ;;
    esac
    ;;
  *BUSY*)
    # A script has been running past busy-reply-threshold. The server is blocked
    # but alive, and a restart is a blunt way to end a script that may be about
    # to finish.
    case "${KIND}" in
      liveness) exit 0 ;;
      *)        fail "busy running a script" ;;
    esac
    ;;
  *)
    fail "ping returned '${answer:-<nothing>}'"
    ;;
esac

# -----------------------------------------------------------------------------
# Extra checks
# -----------------------------------------------------------------------------
for check in "$@"; do
  case "${check}" in

    cluster-state)
      # Cluster mode. A node can answer PING perfectly while having lost the
      # cluster — it stays in the service and returns CLUSTERDOWN to every
      # client that lands on it. PING alone never catches that.
      info="$(timeout 5 "${CLI[@]}" cluster info 2>/dev/null)" || fail "CLUSTER INFO failed"

      known="$(echo "${info}" | grep '^cluster_known_nodes:' | cut -d: -f2 | tr -d '[:space:]')"
      if [ "${known:-1}" -le 1 ]; then
        # This node has not been made part of a cluster yet. That is the normal
        # state between the pod starting and the bootstrap job running, and it
        # has to pass: fail it and every pod restarts in a loop, the job never
        # finds a stable set of nodes to build from, and the cluster is never
        # formed at all.
        exit 0
      fi

      state="$(echo "${info}" | grep '^cluster_state:' | cut -d: -f2 | tr -d '[:space:]')"
      [ "${state}" = "ok" ] || fail "cluster_state is '${state}' with ${known} known nodes"
      ;;

    master-link)
      # Sentinel mode. Only meaningful on a replica: a master has no link to
      # check, and a replica that has lost its own is serving data that is
      # quietly falling behind.
      repl="$(timeout 5 "${CLI[@]}" info replication 2>/dev/null)" || fail "INFO replication failed"
      role="$(echo "${repl}" | grep '^role:' | cut -d: -f2 | tr -d '[:space:]')"
      if [ "${role}" = "slave" ]; then
        link="$(echo "${repl}" | grep '^master_link_status:' | cut -d: -f2 | tr -d '[:space:]')"
        [ "${link}" = "up" ] || fail "replication link to the master is '${link}'"
      fi
      ;;

    *)
      fail "unknown check '${check}'"
      ;;
  esac
done

exit 0
