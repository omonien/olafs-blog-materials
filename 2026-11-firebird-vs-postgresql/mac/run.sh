#!/usr/bin/env bash
# Runs the comparison on macOS with Docker. Both servers run in containers pinned to the same four CPUs of the
# Docker VM; the client runs in a third container that shares the server's network and process namespace, so it
# talks to the server over loopback (no port forwarding through the Docker proxy) and can read the server
# processes' CPU time. The client container uses the PostgreSQL image only as a Debian base for the
# self-contained .NET program.
#
# Build the client first:  dotnet publish dotnet -c Release -r linux-x64 --self-contained -o dotnet/build/linux-x64
# Then:                    mac/run.sh setup         start both servers, fill all tables, print the settings
#                          mac/run.sh round <n>     one round of all tests, Firebird and PostgreSQL alternating
#                          mac/run.sh smoke         every test once with tiny sizes
#                          mac/run.sh stop          remove both containers
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$HERE/dotnet/build/linux-x64"
FB_IMAGE=firebirdsql/firebird:5.0.4-bookworm
PG_IMAGE=postgres:18.6-bookworm
SERVER_CPUS=0-3
CLIENT_CPUS=4-7
LOG=${LOG:-$HERE/results/raw/mac-$(date +%Y-%m-%d).log}
mkdir -p "$(dirname "$LOG")"

log() { echo "$*" | tee -a "$LOG"; }

# Load of the Mac and of the Docker VM, written before every measurement.
load() {
  local mac vm
  mac=$(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')
  vm=$(docker exec cmp-pg cat /proc/loadavg 2>/dev/null | cut -d' ' -f1-3)
  log "LOAD time=$(date '+%Y-%m-%dT%H:%M:%S') mac=\"$mac\" docker_vm=\"$vm\""
}

# bench <fb|pg> <test> [key=value ...]
bench() {
  local engine=$1 test=$2; shift 2
  local container connection
  if [ "$engine" = fb ]; then
    container=cmp-fb
    connection=(fb 127.0.0.1 3050 /var/lib/firebird/data/bench.fdb SYSDBA bench serverproc=firebird)
  else
    container=cmp-pg
    connection=(pg 127.0.0.1 5432 bench bench bench serverproc=postgres)
  fi
  load
  log "=== $engine $test $*"
  docker run --rm --network "container:$container" --pid "container:$container" --cpuset-cpus "$CLIENT_CPUS" \
    -v "$BUILD:/app:ro" --entrypoint /app/DbCompareBench "$PG_IMAGE" "$test" "${connection[@]}" "$@" 2>&1 | tee -a "$LOG"
  [ "${PIPESTATUS[0]}" -eq 0 ] || log "FAILED $engine $test $*"
}

isql() { docker exec -i cmp-fb /opt/firebird/bin/isql -q -user SYSDBA -password bench -ch UTF8 "$@"; }

setup() {
  docker rm -f cmp-fb cmp-pg >/dev/null 2>&1
  # Same CPUs, comparable caches: Firebird 32,768 pages of 8 KB, PostgreSQL shared_buffers 256 MB. Both keep their
  # default durability (forced writes on; fsync and synchronous_commit on). WireCrypt = Enabled lets the client
  # choose; the Firebird default for servers is Required.
  docker run -d --name cmp-fb --cpuset-cpus "$SERVER_CPUS" \
    -e FIREBIRD_ROOT_PASSWORD=bench -e FIREBIRD_DATABASE=bench.fdb -e FIREBIRD_DATABASE_DEFAULT_CHARSET=UTF8 \
    -e FIREBIRD_CONF_DefaultDbCachePages=32768 -e FIREBIRD_CONF_WireCrypt=Enabled "$FB_IMAGE" >/dev/null
  docker run -d --name cmp-pg --cpuset-cpus "$SERVER_CPUS" --shm-size=1g \
    -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=bench "$PG_IMAGE" -c shared_buffers=256MB >/dev/null
  until echo 'SELECT 1 FROM RDB$DATABASE;' | isql 127.0.0.1:/var/lib/firebird/data/bench.fdb >/dev/null 2>&1; do sleep 1; done
  until docker exec cmp-pg pg_isready -q -h 127.0.0.1 -U bench -d bench; do sleep 1; done
  sleep 3
  log "SETUP $(date '+%Y-%m-%dT%H:%M:%S') images $FB_IMAGE $PG_IMAGE, server CPUs $SERVER_CPUS, client CPUs $CLIENT_CPUS"
  load
  local start
  start=$(date +%s)
  isql 127.0.0.1:/var/lib/firebird/data/bench.fdb < "$HERE/firebird/fill-bench-rows.sql" | tee -a "$LOG"
  log "RESULT test=fill engine=fb seconds=$(( $(date +%s) - start ))"
  start=$(date +%s)
  docker exec -i cmp-pg psql -q -U bench -d bench < "$HERE/postgresql/fill-bench-rows.sql" | tee -a "$LOG"
  log "RESULT test=fill engine=pg seconds=$(( $(date +%s) - start ))"
  fsync_test
  for e in fb pg; do bench $e json-setup docs=500000; done
  for e in fb pg; do bench $e probe; done
  for e in fb pg; do bench $e size; done
}

# How expensive a flush is on the containers' disk: both servers pay it on every durable commit.
fsync_test() {
  log "=== pg_test_fsync on the data volume of the containers"
  docker exec cmp-pg pg_test_fsync -s 2 -f /var/lib/postgresql/18/docker/pg_test_fsync.tmp 2>&1 | tee -a "$LOG"
}

smoke() {
  for e in fb pg; do
    bench $e probe
    bench $e read passes=1
    bench $e insert clients=2 seconds=3 warmup=1
    bench $e insert clients=2 seconds=3 warmup=1 durability=relaxed
    bench $e bulk rows=20000 mode=prepared
    bench $e bulk rows=20000 mode=native
    bench $e oltp-setup scale=1
    for s in select simple tpcb; do bench $e oltp script=$s scale=1 clients=4 seconds=3 warmup=1; done
    bench $e json query=lookup-like repeat=1
    bench $e json query=lookup-client repeat=1
    bench $e json query=agg-client repeat=1
  done
  for q in lookup-index lookup-scan agg-sql; do bench pg json query=$q repeat=1; done
}

# One round: every step runs for both engines back to back, the order alternates with the round number.
round() {
  local n=$1 order=(fb pg) step e
  [ $((n % 2)) -eq 0 ] && order=(pg fb)
  log "ROUND $n order ${order[*]}"
  local steps=(
    "read" "read wirecrypt=on"
    "insert clients=1" "insert clients=8"
    "insert clients=1 durability=relaxed" "insert clients=8 durability=relaxed"
    "bulk rows=100000 mode=prepared" "bulk rows=500000 mode=native"
    "oltp-setup scale=10"
  )
  for c in 1 4 16; do steps+=("oltp script=select scale=10 clients=$c seconds=20 warmup=5"); done
  for c in 1 4 16; do steps+=("oltp script=simple scale=10 clients=$c seconds=20 warmup=5"); done
  for c in 1 4 16 64; do steps+=("oltp script=tpcb scale=10 clients=$c seconds=20 warmup=5"); done
  steps+=("json query=lookup-like" "json query=lookup-client" "json query=agg-client")
  for step in "${steps[@]}"; do
    for e in "${order[@]}"; do
      # Wire encryption is a Firebird setting; PostgreSQL runs without TLS throughout.
      [[ $e == pg && $step == *wirecrypt=on* ]] && continue
      # shellcheck disable=SC2086
      bench $e $step
    done
  done
  for q in lookup-index lookup-scan agg-sql; do bench pg json query=$q; done
  bench pg json query=agg-sql parallel=off
  for e in "${order[@]}"; do bench $e size; done
}

case "${1:-}" in
  setup) setup ;;
  fsync) fsync_test ;;
  smoke) smoke ;;
  round) round "${2:?round number}" ;;
  bench) shift; bench "$@" ;;
  stop) docker rm -f cmp-fb cmp-pg ;;
  *) echo "usage: $0 setup | smoke | round <n> | bench <fb|pg> <test> [key=value ...] | stop"; exit 2 ;;
esac
