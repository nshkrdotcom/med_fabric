#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  echo 'Usage: ops/qc_services.sh run [--keep-failure] -- COMMAND [ARGS...]'
  echo '       ops/qc_services.sh status|cleanup PRIVATE_SERVICE_DIR'
  echo 'Runs one command with a fresh loopback PostgreSQL 18 cluster and digest-pinned HAPI R4.'
}
ops=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

read_owner() {
  [[ -d "$state" && -O "$state" && ! -L "$state" && ${state##*/} == fabric-qc-services.* ]]
  [[ -f "$state/owner" && -O "$state/owner" && ! -L "$state/owner" ]]
  read -r name < "$state/owner"
  [[ "$name" =~ ^mf-qc-[a-f0-9]{24}$ ]]
  cid=
  if [[ -f "$state/container" && ! -L "$state/container" ]]; then
    read -r cid < "$state/container"
    [[ "$cid" =~ ^[a-f0-9]{64}$ ]]
  fi
}

postgres_owned() {
  local pid
  local -a args
  [[ -s "$MF_SERVICE_STATE/pgdata/postmaster.pid" ]] || return 1
  read -r pid < "$MF_SERVICE_STATE/pgdata/postmaster.pid"
  [[ "$pid" =~ ^[0-9]+$ && -O /proc/$pid && -r /proc/$pid/cmdline ]] || return 2
  mapfile -d '' -t args < "/proc/$pid/cmdline"
  [[ ${#args[@]} -ge 3 && ${args[0]##*/} == postgres && ${args[1]} == -D &&
    ${args[2]} == "$MF_SERVICE_STATE/pgdata" ]] || return 2
}

stop_postgres() {
  local result=0
  postgres_owned || result=$?
  case "$result" in
    0) "$ops/local_services.sh" stop ;;
    1) return 0 ;;
    2) echo 'Refusing to stop a PostgreSQL process outside this service state.' >&2; return 1 ;;
  esac
}

container_owned() {
  [[ -n "$cid" ]] && [[ "$(docker inspect --format '{{index .Config.Labels "medfabric.qc.owner"}}' "$cid" 2>/dev/null)" == "$name" ]]
}

if [[ ${1:-} == --help ]]; then usage; exit 0; fi
if [[ ${1:-} == status || ${1:-} == cleanup ]]; then
  [[ $# == 2 && ! -L "$2" ]]
  state=$(realpath -e -- "$2")
  read_owner
  export MF_SERVICE_STATE="$state/postgres"
  if [[ $1 == status ]]; then
    if postgres_owned; then echo 'PostgreSQL: running'; else echo 'PostgreSQL: stopped or unowned'; fi
    if container_owned; then docker inspect -f 'Owned HAPI: {{.State.Status}}' "$cid"; else echo 'HAPI: absent or unowned'; fi
    exit 0
  fi
  [[ -f "$state/lifetime.lock" && -O "$state/lifetime.lock" && ! -L "$state/lifetime.lock" ]]
  exec {lifetime_lock}< "$state/lifetime.lock"
  flock -n "$lifetime_lock" || { echo 'This service invocation is still active.' >&2; exit 1; }
  stop_postgres
  if container_owned; then docker rm -f "$cid" >/dev/null; fi
  rm -rf -- "$state"
  exit 0
fi
[[ ${1:-} == run ]] || { usage >&2; exit 2; }
shift
keep_failure=false
if [[ ${1:-} == --keep-failure ]]; then keep_failure=true; shift; fi
[[ ${1:-} == -- && $# -ge 2 ]] || { usage >&2; exit 2; }
shift

image=hapiproject/hapi@sha256:4771a178e764896c83881c1b3a52bd487e53d06e1acc3653ea0db0c6f6b2b8a1
for tool in docker elixir pg_config jq curl flock openssl setsid; do command -v "$tool" >/dev/null; done
export PATH="$(pg_config --bindir):$PATH"
unset DATABASE_URL FHIR_BASE_URL PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE PGOPTIONS
unset MF_SERVICE_STATE MF_POSTGRES_PORT MF_HAPI_PORT
state=$(mktemp -d "${TMPDIR:-/tmp}/fabric-qc-services.XXXXXXXX")
state=$(realpath -e -- "$state")
export MF_SERVICE_STATE="$state/postgres"
export MF_SERVICE_CACHE="$state/cache"
name="mf-qc-$(openssl rand -hex 12)"
printf '%s\n' "$name" > "$state/owner"
exec {lifetime_lock}>"$state/lifetime.lock"
flock "$lifetime_lock"
cid=
child=

stop_child() {
  [[ -n "$child" ]] || return 0
  local parent group
  read -r parent group < <(ps -p "$child" -o ppid=,pgid= 2>/dev/null) || return 0
  [[ "$parent" == "$$" ]] || return 0
  if [[ "$group" == "$child" ]]; then
    kill -TERM -- "-$child" 2>/dev/null || true
    for ((i=0; i<20; i++)); do
      kill -0 -- "-$child" 2>/dev/null || break
      sleep 0.25
    done
    kill -KILL -- "-$child" 2>/dev/null || true
  else
    kill -TERM "$child" 2>/dev/null || true
  fi
  wait "$child" 2>/dev/null || true
}

cleanup() {
  local rc=$?
  local safe_to_remove=true
  trap - EXIT
  stop_child
  stop_postgres || { rc=1; safe_to_remove=false; }
  if container_owned; then
    if ((rc)); then docker logs "$cid" > "$state/hapi.log" 2>&1 || true; fi
    docker rm -f "$cid" >/dev/null || { rc=1; safe_to_remove=false; }
  elif [[ -n "$cid" ]] && docker inspect "$cid" >/dev/null 2>&1; then
    rc=1
    safe_to_remove=false
  fi
  if ! "$safe_to_remove" || { ((rc)) && "$keep_failure"; }; then
    printf 'Private service evidence retained at %s\n' "$state" >&2
  else
    rm -rf -- "$state"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

export MF_POSTGRES_PORT=$(elixir -e '
  {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
  {:ok, {_, port}} = :inet.sockname(socket)
  IO.write(port)
  :gen_tcp.close(socket)
')
(
  exec {lifetime_lock}>&-
  exec "$ops/local_services.sh" postgres
) > "$state/postgres.env"
# local_services.sh emits shell-escaped assignments for these two variables.
source "$state/postgres.env"
rm "$state/postgres.env"
[[ "$(psql "$DATABASE_URL" -XAt -v ON_ERROR_STOP=1 -c 'SHOW data_directory')" == "$MF_SERVICE_STATE/pgdata" ]]
[[ "$(psql "$DATABASE_URL" -XAt -v ON_ERROR_STOP=1 -c 'SELECT 1')" == 1 ]]

# Create first so cleanup has the exact owned container ID even when start fails.
cid=$(docker create --name "$name" --label "medfabric.qc.owner=$name" -p 127.0.0.1::8080 "$image")
printf '%s\n' "$cid" > "$state/container"
docker start "$cid" >/dev/null
port=$(docker port "$cid" 8080/tcp | awk -F: '/^127\.0\.0\.1:/{print $NF}')
[[ "$port" =~ ^[0-9]+$ ]]
export FHIR_BASE_URL="http://127.0.0.1:$port/fhir"
ready=false
for ((i=0; i<120; i++)); do
  if curl --noproxy '*' --max-time 3 -fsS "$FHIR_BASE_URL/metadata" 2>/dev/null |
      jq -e '.fhirVersion == "4.0.1"' >/dev/null; then
    ready=true
    break
  fi
  [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" == true ]] || break
  sleep 1
done
"$ready" || { echo 'Owned HAPI did not reach R4 readiness.' >&2; exit 1; }
printf 'Owned PostgreSQL 18 and pinned HAPI R4 ready.\n' >&2

(
  exec {lifetime_lock}>&-
  exec setsid -- "$@"
) &
child=$!
wait "$child"
