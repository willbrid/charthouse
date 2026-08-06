#!/bin/bash
# =============================================================================
# Backup — pulls a fresh RDB out of Redis and writes it to the backup volume
# =============================================================================
#
# `redis-cli --rdb` asks the instance for a full synchronisation and writes what
# comes back, exactly as a replica would. Two consequences worth knowing before
# you schedule this:
#
#   - the dump is CONSISTENT. It is a point-in-time snapshot produced by Redis
#     itself, not a copy of a file being written to underneath us. Copying
#     dump.rdb off the volume would give you neither guarantee.
#   - it COSTS a fork on the instance it runs against. The copy-on-write pages
#     of a busy 16GB instance are not free, which is why this runs at night by
#     default, and why backup.target lets you keep it off the master.
#
# What it does not protect against, and nothing else here does either: a
# mistaken FLUSHALL replicates to every replica in milliseconds. A dump held
# somewhere Redis cannot reach is the only answer to that, which is what
# backup.storage and postBackupScript are for.
#
# Everything here comes from the environment, set by the chart in the pod spec.
# =============================================================================
set -euo pipefail

log() { echo "backup: $*"; }
die() { echo "backup: $*" >&2; exit 1; }

: "${FULLNAME:?}" "${HEADLESS_SERVICE:?}" "${POD_NAMESPACE:?}" "${CLUSTER_DOMAIN:?}"
: "${REDIS_PORT:?}" "${REPLICA_COUNT:?}" "${REDIS_MODE:?}" "${BACKUP_TARGET:?}"
: "${BACKUP_DIR:?}" "${RETENTION_DAYS:?}"

peer_fqdn() {
  echo "${FULLNAME}-${1}.${HEADLESS_SERVICE}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN}"
}

cli() { timeout 30 redis-cli -t 10 "$@"; }

role_of() {
  cli -h "$1" -p "${REDIS_PORT}" info replication 2>/dev/null \
    | grep '^role:' | cut -d: -f2 | tr -d '[:space:]'
}

# -----------------------------------------------------------------------------
# Which instances to dump
# -----------------------------------------------------------------------------
TARGETS=()

case "${BACKUP_TARGET}" in
  all)
    # Every pod. In cluster mode this is the only correct answer — each master
    # holds a different share of the keyspace, so a restore needs all of them.
    for (( i = 0; i < REPLICA_COUNT; i++ )); do
      TARGETS+=("$(peer_fqdn "$i")")
    done
    ;;

  master)
    # Ask sentinel rather than guessing. Which pod leads changes with every
    # failover, and a backup of yesterday's master is a backup of a replica.
    for (( i = 0; i < REPLICA_COUNT; i++ )); do
      out="$(timeout 5 env -u REDISCLI_AUTH redis-cli -h "$(peer_fqdn "$i")" -p "${SENTINEL_PORT:?}" -t 3 \
               sentinel get-master-addr-by-name "${SENTINEL_MASTER_SET:?}" 2>/dev/null)" || continue
      host="$(echo "${out}" | sed -n 1p | tr -d '\r')"
      if [ -n "${host}" ]; then
        TARGETS+=("${host}")
        break
      fi
    done
    [ ${#TARGETS[@]} -gt 0 ] || die "no sentinel could name the master"
    ;;

  replica)
    for (( i = 0; i < REPLICA_COUNT; i++ )); do
      host="$(peer_fqdn "$i")"
      [ "$(role_of "${host}")" = "slave" ] && TARGETS+=("${host}")
    done
    [ ${#TARGETS[@]} -gt 0 ] || die "no replica answered; every instance reports itself as a master"
    ;;

  *)
    die "unknown BACKUP_TARGET '${BACKUP_TARGET}'"
    ;;
esac

# -----------------------------------------------------------------------------
# Dump
# -----------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${BACKUP_DIR}/${STAMP}"
mkdir -p "${RUN_DIR}"

log "dumping ${#TARGETS[@]} instance(s) into ${RUN_DIR}"

failed=0
for host in "${TARGETS[@]}"; do
  short="${host%%.*}"
  file="${RUN_DIR}/${short}.rdb"

  log "  ${host} -> ${file}"
  if ! redis-cli -h "${host}" -p "${REDIS_PORT}" --no-auth-warning --rdb "${file}"; then
    log "  FAILED: ${host}"
    failed=$(( failed + 1 ))
    continue
  fi

  # An RDB that cannot be read back is not a backup, and the only moment worth
  # finding that out is now rather than during a restore.
  if ! redis-check-rdb "${file}" >/dev/null 2>&1; then
    log "  FAILED: ${file} did not pass redis-check-rdb"
    failed=$(( failed + 1 ))
    continue
  fi

  size="$(du -h "${file}" | cut -f1)"
  log "  ok, ${size}"

  if [ -n "${POST_BACKUP_SCRIPT:-}" ]; then
    log "  running the post-backup script"
    BACKUP_FILE="${file}" BACKUP_DIR="${RUN_DIR}" bash -c "${POST_BACKUP_SCRIPT}"
  fi
done

# -----------------------------------------------------------------------------
# Retention
# -----------------------------------------------------------------------------
#
# After the dumps, never before: a failed run must not be the thing that deletes
# the last good backup.
if [ "${RETENTION_DAYS}" -gt 0 ] && [ "${failed}" -eq 0 ]; then
  log "removing runs older than ${RETENTION_DAYS} day(s)"
  find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" \
    -print -exec rm -rf {} +
elif [ "${failed}" -gt 0 ]; then
  log "keeping every previous run: ${failed} dump(s) failed in this one"
fi

[ "${failed}" -eq 0 ] || die "${failed} of ${#TARGETS[@]} dump(s) failed"

log "done: ${RUN_DIR}"
