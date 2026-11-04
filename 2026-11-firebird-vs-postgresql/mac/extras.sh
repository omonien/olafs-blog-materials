#!/usr/bin/env bash
# Additional checks after the rounds of mac/run.sh, on the same containers:
# - pgbench itself drives the PostgreSQL side (from a client container on the client CPUs), as a cross-check of
#   the .NET client for the three oltp scripts;
# - 200,000 lookups and updates inside each server (PSQL and PL/pgSQL), to separate engine cost from round trips;
# - the wire encryption Firebird negotiates with FirebirdClient;
# - table sizes in Firebird (gstat), next to the sizes PostgreSQL reports.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PG_IMAGE=postgres:18.6-bookworm
CLIENT_CPUS=4-7
LOG=${LOG:-$HERE/results/raw/mac-extras-$(date +%Y-%m-%d).log}

log() { echo "$*" | tee -a "$LOG"; }
load() {
  log "LOAD time=$(date '+%Y-%m-%dT%H:%M:%S') mac=\"$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')\" docker_vm=\"$(docker exec cmp-pg cat /proc/loadavg | cut -d' ' -f1-3)\""
}

pgbench_run() {
  local script=$1 clients=$2 flag
  case $script in select) flag=-S ;; simple) flag=-N ;; *) flag= ;; esac
  load
  log "=== pgbench $script clients=$clients"
  docker run --rm --network container:cmp-pg --cpuset-cpus "$CLIENT_CPUS" -e PGPASSWORD=bench --entrypoint pgbench "$PG_IMAGE" \
    -h 127.0.0.1 -U bench -n -M prepared $flag -c "$clients" -j "$clients" -T 20 bench 2>&1 | tee -a "$LOG" |
    awk -v s="$script" -v c="$clients" '/^tps = /{print "RESULT test=pgbench engine=pg script=" s " clients=" c " tps=" $3}' | tee -a "$LOG"
}

what=${1:-all}
want() { [[ $what == all || $what == "$1" ]]; }

if want pgbench; then
  for s in select simple tpcb; do for c in 1 4 16; do pgbench_run $s $c; done; done
fi
if want server-side; then
  load
  log "=== fb server-side lookups and updates"
  docker exec -i cmp-fb /opt/firebird/bin/isql -q -user SYSDBA -password bench 127.0.0.1:/var/lib/firebird/data/bench.fdb \
    < "$HERE/firebird/server-side-lookups.sql" 2>&1 | tee -a "$LOG"
  load
  log "=== pg server-side lookups and updates"
  docker exec -i -e PGPASSWORD=bench cmp-pg psql -h 127.0.0.1 -U bench -d bench < "$HERE/postgresql/server-side-lookups.sql" 2>&1 | tee -a "$LOG"
fi
if want wirecrypt; then
  log "=== fb probe wirecrypt=on"
  docker run --rm --network container:cmp-fb --cpuset-cpus "$CLIENT_CPUS" -v "$HERE/dotnet/build/linux-x64:/app:ro" \
    --entrypoint /app/DbCompareBench "$PG_IMAGE" probe fb 127.0.0.1 3050 /var/lib/firebird/data/bench.fdb SYSDBA bench wirecrypt=on 2>&1 |
    grep -E 'wire_' | tee -a "$LOG"
fi
if want sizes; then
  log "=== fb gstat data pages"
  docker exec cmp-fb /opt/firebird/bin/gstat -d -user SYSDBA -password bench /var/lib/firebird/data/bench.fdb 2>&1 |
    grep -E '^[A-Z_]+ \(|Primary pointer|Data pages:|Average record length|Average version length' | tee -a "$LOG"
fi
