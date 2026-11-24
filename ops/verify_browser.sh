#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077

for tool in mix node openssl curl psql jq ps timeout; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool. Run ./onboard.sh --integration." >&2; exit 1; }
done
[[ -d ops/node_modules/playwright ]] || { echo "Run ./onboard.sh --integration." >&2; exit 1; }

mode="${1:-}"
[[ -z "$mode" || "$mode" == "--release" ]] || { echo "Usage: $0 [--release]" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/med-fabric-browser.XXXXXXXX")"
export MF_EXAM_LEGACY_MEDIA=1
export MF_EXAM_ID="exam-$(openssl rand -hex 8)"
export MF_LAB=1
export MF_HTTP_PORT="${MF_HTTP_PORT:-14000}"
export MF_PATIENT_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_CLINICIAN_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_PATIENT_ACTOR="patient"
export MF_CLINICIAN_ACTOR="clinician"
export MF_SECRET_KEY_BASE="$(openssl rand -hex 48)"
export MF_ARTIFACT_DIR="$work/recordings"
export MF_SERVICE_STATE="$work/services"

owns_hapi=false
[[ -n "${FHIR_BASE_URL:-}" ]] || owns_hapi=true
pid=""
exam_alive() {
  local parent
  [[ -n "$pid" ]] || return 1
  parent="$(ps -p "$pid" -o ppid= 2>/dev/null)" || return 1
  [[ "${parent//[[:space:]]/}" == "$$" ]] && kill -0 "$pid" 2>/dev/null
}
stop_exam() {
  local attempt
  [[ -n "$pid" ]] || return 0

  if exam_alive; then
    kill -TERM "$pid" 2>/dev/null || true
    for ((attempt=0; attempt<20; attempt++)); do
      exam_alive || break
      sleep 0.25
    done
  fi
  if exam_alive; then
    kill -KILL "$pid" 2>/dev/null || true
    for ((attempt=0; attempt<8; attempt++)); do
      exam_alive || break
      sleep 0.25
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    echo "Exam exit could not be confirmed. Evidence directory $work" >&2
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  pid=""
}
cleanup() {
  local status=$? stopped=true
  trap - EXIT
  stop_exam || stopped=false
  if [[ "$MF_SERVICE_STATE" == "$work/services" && -d "$MF_SERVICE_STATE" ]]; then
    ops/local_services.sh stop || stopped=false
  fi
  if ! "$stopped"; then
    printf 'Service cleanup failed. Evidence directory %s\n' "$work" >&2
    exit 1
  elif [[ "${MF_BROWSER_KEEP:-0}" == 1 ]]; then
    printf 'Evidence directory %s\n' "$work"
  else
    rm -rf -- "$work"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -z "${DATABASE_URL:-}" || -z "${FHIR_BASE_URL:-}" ]]; then
  native_env="$(ops/local_services.sh start)"
  eval "$native_env"
fi

psql -Xq "$DATABASE_URL" -c 'SELECT 1' >/dev/null
curl -fsS --max-time 5 -H 'Accept: application/fhir+json' "${FHIR_BASE_URL%/}/metadata" |
  jq -e '.fhirVersion == "4.0.1"' >/dev/null


export MF_ENCOUNTERS_FILE="$work/refs.json"
for mix_env in dev test; do
  (cd apps/exam && env -u MF_LAB MIX_ENV="$mix_env" mix deps.get)
done
(cd apps/exam && env -u MF_LAB mix run --no-start ../../ops/seed_exam.exs)

# Native transition checks share the browser verifier's isolated services.
# Core projects have their own dependency/build roots outside the exam overlay.
for package in core/store core/interop; do
  (cd "$package" && env -u MIX_EXS -u MIX_DEPS_PATH -u MIX_BUILD_PATH -u MIX_BUILD_ROOT -u MIX_LOCKFILE \
    -u MF_MED_EX_PATH -u MIX_ENV -u MF_LAB mix test integration)
done
(cd apps/exam && env -u MF_LAB mix test integration/{recording,encounter_scope}_test.exs)

if [[ "$mode" == "--release" ]]; then
  (cd apps/exam && export MIX_ENV=prod && unset MF_LAB && mix deps.get &&
    mix release --path "$work/release" --overwrite) >"$work/release.log" 2>&1 ||
    { cat "$work/release.log" >&2; exit 1; }
fi

start_exam() {
  local attempt probe=0
  [[ "$MF_HTTP_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$MF_HTTP_PORT >= 1024 && 10#$MF_HTTP_PORT <= 65535 )) ||
    { echo "Invalid MF_HTTP_PORT: $MF_HTTP_PORT" >&2; return 1; }
  timeout 2 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$MF_HTTP_PORT" 2>/dev/null || probe=$?
  if [[ "$probe" != 1 ]]; then
    echo "Exam port $MF_HTTP_PORT is occupied or could not be checked." >&2
    return 1
  fi

  if [[ "$mode" == "--release" ]]; then
    (cd "$work" && exec "$work/release/bin/mf_exam" start) >>"$work/exam.log" 2>&1 &
  else
    (cd apps/exam && exec mix run --no-halt) >>"$work/exam.log" 2>&1 &
  fi
  pid=$!
  for ((attempt=0; attempt<120; attempt++)); do
    exam_alive || break
    if [[ "$(curl -sS --noproxy '*' --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MF_HTTP_PORT/encounters/$MF_EXAM_ID" 2>/dev/null || true)" == 403 ]] &&
      exam_alive; then
      return
    fi
    sleep 1
  done
  cat "$work/exam.log" >&2
  return 1
}

start_exam
node ops/browser/check.mjs --capture
stop_exam
start_exam
node ops/browser/check.mjs
stop_exam
if "$owns_hapi"; then ops/local_services.sh restart-hapi; fi
start_exam
node ops/browser/check.mjs --after-restart
