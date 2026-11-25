#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lab="${MF_DEV_LAB:-$repo_root/_build/handheld-demo}"
preview_port="${MF_PREVIEW_PORT:-4090}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

find_pg_bin() {
  if command -v pg_ctl >/dev/null 2>&1 && command -v initdb >/dev/null 2>&1; then
    dirname "$(command -v pg_ctl)"
    return 0
  fi

  if command -v pg_config >/dev/null 2>&1; then
    local bindir
    bindir="$(pg_config --bindir)"
    if [[ -x "$bindir/pg_ctl" && -x "$bindir/initdb" ]]; then
      printf '%s\n' "$bindir"
      return 0
    fi
  fi

  local dir
  for dir in /usr/lib/postgresql/*/bin /usr/local/pgsql/bin; do
    if [[ -x "$dir/pg_ctl" && -x "$dir/initdb" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done

  die "PostgreSQL server binaries (initdb, pg_ctl) not found. Install postgresql or add its bin dir to PATH."
}

require_tools() {
  local tool
  for tool in elixir mix jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || die "Missing required tool: $tool"
  done
}

ensure_prepared() {
  if [[ ! -f "$lab/server.json" ]]; then
    (cd "$repo_root" && elixir ops/handheld_demo.exs prepare --run-dir "$lab")
  fi

  local cred="$lab/preview.credential"
  if [[ ! -s "$cred" ]]; then
    openssl rand -hex 32 > "$cred"
    chmod 600 "$cred"
  fi

  local tmp="$lab/server.json.tmp"
  jq --arg url "http://127.0.0.1:${preview_port}" --arg cred "$cred" \
    '. + {preview_url: $url, preview_credential_file: $cred}' \
    "$lab/server.json" > "$tmp"
  mv "$tmp" "$lab/server.json"
}

pg_running() {
  local pg_bin="$1"
  [[ -d "$lab/pgdata" ]] && "$pg_bin/pg_ctl" -D "$lab/pgdata" status >/dev/null 2>&1
}

ensure_postgres_up() {
  local pg_bin pg_port
  pg_bin="$(find_pg_bin)"
  pg_port="$(jq -er .postgres_port "$lab/server.json")"

  mkdir -p "$lab/logs" "$lab/pghost"

  if [[ ! -f "$lab/pgdata/PG_VERSION" ]]; then
    "$pg_bin/initdb" -D "$lab/pgdata" -U lab --auth-local=trust --auth-host=scram-sha-256 \
      --pwfile="$lab/postgres.credential" --no-locale >/dev/null
  fi

  if ! pg_running "$pg_bin"; then
    "$pg_bin/pg_ctl" -D "$lab/pgdata" -l "$lab/logs/postgres.log" \
      -o "-k $lab/pghost -h 127.0.0.1 -p $pg_port" start >/dev/null
  fi
}

print_url() {
  [[ -f "$lab/server.json" ]] || die "Dev lab not prepared yet. Run: ops/dev.sh up"
  jq -r '"http://localhost:\(.http_port)/encounters/\(.encounters[0].exam)?key=\(.encounters[0].clinician_key)"' \
    "$lab/server.json"
}

cmd_up() {
  require_tools
  ensure_prepared
  ensure_postgres_up

  local url
  url="$(print_url)"

  cat <<EOF
Med Fabric dev lab is ready: $lab
PostgreSQL: running on 127.0.0.1:$(jq -er .postgres_port "$lab/server.json")
Review URL: $url

Next, open 3 terminals from $repo_root:
  Terminal 1 (Preview):  ./ops/dev.sh preview
  Terminal 2 (Exam):     ./ops/dev.sh exam
  Terminal 3 (Handheld): ./ops/dev.sh handheld

Stop Postgres when done: ./ops/dev.sh down
EOF
}

cmd_preview() {
  require_tools
  [[ -f "$lab/preview.credential" ]] || die "Dev lab not prepared. Run: ./ops/dev.sh up"
  cd "$repo_root/apps/preview"
  exec env \
    MF_PREVIEW_PORT="$preview_port" \
    MF_PREVIEW_CREDENTIAL_FILE="$lab/preview.credential" \
    mix run --no-halt
}

cmd_exam() {
  require_tools
  [[ -f "$lab/server.json" ]] || die "Dev lab not prepared. Run: ./ops/dev.sh up"
  local pg_bin
  pg_bin="$(find_pg_bin)"
  pg_running "$pg_bin" || die "PostgreSQL is not running. Run: ./ops/dev.sh up"
  cd "$repo_root/apps/exam"
  exec mix run --no-start --no-halt "$repo_root/ops/run_exam.exs" --config "$lab/server.json"
}

cmd_handheld() {
  require_tools
  [[ -f "$lab/handheld-a.json" ]] || die "Dev lab not prepared. Run: ./ops/dev.sh up"

  local scenario="${1:-paired_exam}"
  local config="$lab/handheld-a.json"

  if [[ "$scenario" == "plx_spot_check" ]]; then
    config="$lab/handheld-plx-$(date +%s).json"
    jq --arg acq "plx-$(openssl rand -hex 6)" '. + {acquisition: $acq}' \
      "$lab/handheld-a.json" > "$config"
  fi

  (cd "$repo_root" && elixir ops/handheld_demo.exs relay --run-dir "$lab") &
  RELAY_PID=$!
  trap 'kill "${RELAY_PID:-}" 2>/dev/null || true; wait "${RELAY_PID:-}" 2>/dev/null || true' EXIT INT TERM
  sleep 1

  cd "$repo_root/apps/handheld"
  mix run -e 'MedExHandheld.CLI.main(System.argv())' -- \
    --config "$config" --scenario "$scenario"
}

cmd_status() {
  if [[ ! -f "$lab/server.json" ]]; then
    echo "Dev lab: not prepared ($lab)"
    return 0
  fi

  local pg_bin pg_state="stopped"
  pg_bin="$(find_pg_bin)"
  if pg_running "$pg_bin"; then
    pg_state="running (127.0.0.1:$(jq -er .postgres_port "$lab/server.json"))"
  fi

  echo "Dev lab:    $lab"
  echo "PostgreSQL: $pg_state"
  echo "Preview:    http://127.0.0.1:${preview_port}"
  echo "Review URL: $(print_url)"
}

cmd_down() {
  if [[ -d "$lab/pgdata" ]]; then
    local pg_bin
    pg_bin="$(find_pg_bin)"
    if pg_running "$pg_bin"; then
      "$pg_bin/pg_ctl" -D "$lab/pgdata" stop -m fast >/dev/null
      echo "Stopped PostgreSQL ($lab/pgdata)"
    else
      echo "PostgreSQL is already stopped."
    fi
  else
    echo "No PostgreSQL data directory at $lab/pgdata"
  fi
}

cmd_reset() {
  cmd_down
  rm -rf "$lab"
  echo "Removed $lab"
}

usage() {
  cat <<'EOF'
Usage: ./ops/dev.sh <command>

Commands:
  up                         Prepare dev lab, Preview secret, and start PostgreSQL
  preview                    Start isolated mf_preview sidecar (Terminal 1)
  exam                       Start mf_exam server (Terminal 2)
  handheld [scenario]        Start TLS relay + mf_handheld client (Terminal 3)
                             Scenarios: paired_exam (default), plx_spot_check
  url                        Print clinician review browser URL
  status                     Show dev lab and PostgreSQL status
  down                       Stop isolated PostgreSQL
  reset                      Stop PostgreSQL and remove dev lab state
EOF
}

case "${1:-}" in
  up) cmd_up ;;
  preview) cmd_preview ;;
  exam) cmd_exam ;;
  handheld) shift; cmd_handheld "$@" ;;
  url) print_url ;;
  status) cmd_status ;;
  down) cmd_down ;;
  reset) cmd_reset ;;
  -h|--help|"") usage ;;
  *) die "Unknown command: $1 (run ./ops/dev.sh --help)" ;;
esac
