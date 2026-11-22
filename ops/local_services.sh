#!/usr/bin/env bash
set -euo pipefail
umask 077

state="${MF_SERVICE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/med-fabric}"
cache="${MF_SERVICE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/med-fabric}"
pg_port="${MF_POSTGRES_PORT:-15432}"
hapi_port="${MF_HAPI_PORT:-18080}"
maven_version=3.9.11
hapi_revision=103fd012c060d9fe0fd2cc3adc0048857ea9976e
hapi_source="$cache/hapi-fhir-jpaserver-starter-$hapi_revision"
hapi_archive="$hapi_source/target/ROOT.war"
native_db_url="postgresql://med_fabric@127.0.0.1:$pg_port/med_fabric_dev"
native_fhir_url="http://127.0.0.1:$hapi_port/fhir"

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1024 && 10#$port <= 65535 )) ||
    die "Configure a port between 1024 and 65535: $port"
}

pg_bin() {
  if command -v pg_ctl >/dev/null; then
    dirname "$(command -v pg_ctl)"
  elif command -v pg_config >/dev/null; then
    pg_config --bindir
  else
    die "Install PostgreSQL server binaries and add their bin directory to PATH."
  fi
}

start_postgres() {
  local bin
  bin="$(pg_bin)"
  for name in initdb pg_ctl createdb psql; do
    [[ -x "$bin/$name" ]] || die "Missing PostgreSQL server executable: $bin/$name"
  done
  "$bin/initdb" --version | grep -Eq '^initdb \(PostgreSQL\) 18\.' ||
    die "Activate PostgreSQL 18 binaries."
  if [[ ! -s "$state/pgdata/PG_VERSION" ]]; then
    "$bin/initdb" -D "$state/pgdata" --username=med_fabric --encoding=UTF8 --locale=C --auth=trust >>"$state/postgres.log" 2>&1 ||
      die "PostgreSQL initialization failed. See $state/postgres.log"
  fi

  if ! "$bin/pg_ctl" -D "$state/pgdata" status >/dev/null; then
    "$bin/pg_ctl" -D "$state/pgdata" -l "$state/postgres.log" \
      -o "-h 127.0.0.1 -p $pg_port -k ''" -w start >&2 ||
      die "PostgreSQL startup failed. See $state/postgres.log"
  fi

  if ! "$bin/psql" -Xq "$native_db_url" -c 'SELECT 1' >/dev/null 2>&1; then
    "$bin/createdb" --host=127.0.0.1 --port="$pg_port" --username=med_fabric med_fabric_dev
  fi
}

verified_tar() {
  local url="$1" digest="$2" archive="$3" actual
  if [[ ! -f "$archive" ]]; then
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 "$url" -o "$archive.partial"
    mv "$archive.partial" "$archive"
  fi
  actual="$(shasum -a 256 "$archive")"
  [[ "${actual%% *}" == "$digest" ]] ||
    die "Checksum mismatch for $archive. Remove the cached archive and retry."
}

build_hapi() {
  local maven="$cache/apache-maven-$maven_version"
  if [[ ! -x "$maven/bin/mvn" ]]; then
    verified_tar \
      "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/$maven_version/apache-maven-$maven_version-bin.tar.gz" \
      4b7195b6a4f5c81af4c0212677a32ee8143643401bc6e1e8412e6b06ea82beac \
      "$cache/apache-maven-$maven_version-bin.tar.gz"
    tar -xzf "$cache/apache-maven-$maven_version-bin.tar.gz" -C "$cache"
  fi
  if [[ ! -f "$hapi_source/pom.xml" ]]; then
    verified_tar \
      "https://codeload.github.com/hapifhir/hapi-fhir-jpaserver-starter/tar.gz/$hapi_revision" \
      ac41a9845d5055fd2c2b084298713147124dae4451b7218da4aad929a4337791 \
      "$cache/hapi-$hapi_revision.tar.gz"
    tar -xzf "$cache/hapi-$hapi_revision.tar.gz" -C "$cache"
  fi

  printf 'Building pinned HAPI FHIR 7.6.0. See %s.\n' "$state/hapi-build.log" >&2
  (
    cd "$hapi_source"
    "$maven/bin/mvn" -B -DskipTests -Pboot package spring-boot:repackage
  ) >"$state/hapi-build.log" 2>&1 ||
    die "HAPI build failed. See $state/hapi-build.log"
  [[ -f "$hapi_archive" ]] || die "HAPI build did not produce $hapi_archive"
  touch "$cache/hapi-$hapi_revision.built"
}

hapi_pid() {
  local pid
  [[ -f "$state/hapi.pid" ]] || return 1
  read -r pid <"$state/hapi.pid"
  [[ "$pid" =~ ^[0-9]+$ ]] && ps -p "$pid" -o args= | grep -Fq -- "$hapi_archive" || return 1
  printf '%s\n' "$pid"
}

wait_hapi() {
  local fhir_url="$1"
  local attempt
  for ((attempt=0;attempt<90;attempt++)); do
    if curl -fsS --max-time 2 -H 'Accept: application/fhir+json' "${fhir_url%/}/metadata" 2>/dev/null |
      jq -e '.fhirVersion == "4.0.1"' >/dev/null; then
      return 0
    fi
    sleep 2
  done

  die "FHIR R4 metadata never became ready at $fhir_url. See $state/hapi.log for local HAPI."
}

start_hapi() {
  local java=java
  [[ -z "${JAVA_HOME:-}" ]] || java="$JAVA_HOME/bin/java"
  local javac
  javac="$(dirname "$java")/javac"
  if [[ "$java" == "java" ]]; then javac=javac; fi
  command -v "$java" >/dev/null && command -v "$javac" >/dev/null ||
    die "Install a full JDK and set JAVA_HOME or PATH."
  "$javac" -version 2>&1 | grep -Fqx 'javac 21.0.9' ||
    die "Activate the pinned JDK. Use mise install java@temurin-21.0.9+10 and set JAVA_HOME."
  if [[ ! -f "$hapi_archive" || ! -f "$cache/hapi-$hapi_revision.built" ]]; then
    build_hapi
  fi

  if ! hapi_pid >/dev/null; then
    (
      cd "$state"
      nohup "$java" -Xms128m -Xmx1g -jar "$hapi_archive" \
        --server.address=127.0.0.1 --server.port="$hapi_port" \
        --hapi.fhir.fhir_version=R4 --hapi.fhir.allow_multiple_delete=false \
        </dev/null >"$state/hapi.log" 2>&1 &
      printf '%s\n' "$!" >"$state/hapi.pid"
    )
  fi
}

print_env() {
  printf 'export DATABASE_URL=%q\n' "${DATABASE_URL:-$native_db_url}"
  printf 'export FHIR_BASE_URL=%q\n' "${FHIR_BASE_URL:-$native_fhir_url}"
}

case "${1:-}" in
  start|postgres)
    for tool in curl jq shasum tar; do
      command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
    done
    validate_port "$pg_port"
    validate_port "$hapi_port"
    mkdir -p "$state" "$cache"
    state="$(cd "$state" && pwd)"
    cache="$(cd "$cache" && pwd)"
    hapi_source="$cache/hapi-fhir-jpaserver-starter-$hapi_revision"
    hapi_archive="$hapi_source/target/ROOT.war"
    [[ -n "${DATABASE_URL:-}" ]] || start_postgres
    if [[ "$1" == "start" ]]; then
      [[ -n "${FHIR_BASE_URL:-}" ]] || start_hapi
      wait_hapi "${FHIR_BASE_URL:-$native_fhir_url}"
    fi
    print_env
    ;;
  env)
    print_env
    ;;
  stop)
    if pid="$(hapi_pid)"; then
      kill "$pid"
    fi
    if [[ -s "$state/pgdata/PG_VERSION" ]]; then
      bin="$(pg_bin)"
      if "$bin/pg_ctl" -D "$state/pgdata" status >/dev/null; then
        "$bin/pg_ctl" -D "$state/pgdata" -m fast -w stop
      fi
    fi
    ;;
  *)
    die 'Usage: ops/local_services.sh start|postgres|env|stop'
    ;;
esac
