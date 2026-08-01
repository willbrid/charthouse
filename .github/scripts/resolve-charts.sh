#!/usr/bin/env bash
# Resolve a comma-separated chart selection into chart directories, one per line.
#
# Accepts "fluentbit", "charts/fluentbit" or any mix of the two, and tolerates
# spaces around the separators. An unknown chart is fatal: a typo in a manual run
# must stop the pipeline, never silently narrow what is tested or published.
#
# Shared by lint-test.yml and release.yml so that a manual release tests exactly
# the charts it publishes.
#
# Usage: .github/scripts/resolve-charts.sh "fluentbit, charts/grafana"

set -euo pipefail
# Chart names are split on commas and must never be expanded as globs.
set -o noglob

selection="${1:-}"
[ -n "$selection" ] || exit 0

resolved=""
missing=""

IFS=','
for raw in $selection; do
  name="$(echo "$raw" | tr -d '[:space:]')"
  [ -n "$name" ] || continue
  # Both "fluentbit" and "charts/fluentbit" designate the same directory.
  dir="charts/${name#charts/}"
  if [ -d "$dir" ]; then
    resolved="$(printf '%s\n%s' "$resolved" "$dir")"
  else
    missing="$(printf '%s %s' "$missing" "$name")"
  fi
done
unset IFS

if [ -n "$missing" ]; then
  echo "::error::Unknown chart(s):$missing" >&2
  exit 1
fi

echo "$resolved" | sed '/^$/d' | sort -u
