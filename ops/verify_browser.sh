#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077

for tool in mix node openssl curl psql jq; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool. Run ./onboard.sh --integration." >&2; exit 1; }
done
[[ -d ops/browser/node_modules/playwright ]] || { echo "Run ./onboard.sh --integration." >&2; exit 1; }

export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$PWD/_build/playwright}"
mode="${1:-}"
[[ -z "$mode" || "$mode" == "--release" ]] || { echo "Usage: $0 [--release]" >&2; exit 1; }

mkdir -p _build
work="$(mktemp -d "$PWD/_build/browser.XXXXXXXX")"
export MF_EXAM_ID="exam-$(openssl rand -hex 8)"
export MF_LAB=1
export MF_HTTP_PORT="${MF_HTTP_PORT:-14000}"
export MF_PATIENT_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_CLINICIAN_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_PATIENT_ACTOR="patient"
export MF_CLINICIAN_ACTOR="clinician"
export MF_SECRET_KEY_BASE="$(openssl rand -hex 48)"
export MF_ARTIFACT_DIR="$work/recordings"
export MF_SERVICE_STATE="${MF_SERVICE_STATE:-$work/services}"

owns_hapi=false
[[ -n "${FHIR_BASE_URL:-}" ]] || owns_hapi=true
pid=""
stop_exam() {
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" || true
    pid=""
  fi
}
cleanup() {
  stop_exam
  if [[ "$MF_SERVICE_STATE" == "$work/services" && -d "$MF_SERVICE_STATE" ]]; then
    ops/local_services.sh stop
  fi
}
trap cleanup EXIT

if [[ -z "${DATABASE_URL:-}" || -z "${FHIR_BASE_URL:-}" ]]; then
  native_env="$(ops/local_services.sh start)"
  eval "$native_env"
fi

psql -Xq "$DATABASE_URL" -c 'SELECT 1' >/dev/null
curl -fsS --max-time 5 -H 'Accept: application/fhir+json' "${FHIR_BASE_URL%/}/metadata" |
  jq -e '.fhirVersion == "4.0.1"' >/dev/null


export MF_ENCOUNTERS_FILE="$work/refs.json"
(cd apps/exam && env -u MF_LAB mix run --no-start ../../ops/seed_exam.exs)

# Native transition checks share the browser verifier's isolated services.
# Core projects have their own dependency/build roots outside the exam overlay.
for package in core/store core/interop; do
  (cd "$package" && env -u MIX_EXS -u MIX_DEPS_PATH -u MIX_BUILD_PATH -u MIX_LOCKFILE \
    -u MIX_WORKSPACE_OPS_BOOTSTRAP -u MIX_ENV -u MF_LAB mix test integration)
done
(cd apps/exam && env -u MF_LAB MIX_ENV=test mix test integration)

if [[ "$mode" == "--release" ]]; then
  (cd apps/exam && env -u MF_LAB MIX_ENV=prod MIX_BUILD_PATH="$work/prod-build" mix release --path "$work/release" --overwrite) >"$work/release.log" 2>&1 ||
    { cat "$work/release.log" >&2; exit 1; }
fi

start_exam() {
  if [[ "$mode" == "--release" ]]; then
    (cd apps/exam && exec "$work/release/bin/mf_exam" start) >>"$work/exam.log" 2>&1 &
  else
    (cd apps/exam && exec mix run --no-halt) >>"$work/exam.log" 2>&1 &
  fi
  pid=$!
  for ((attempt=0; attempt<120; attempt++)); do
    if [[ "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MF_HTTP_PORT/encounters/$MF_EXAM_ID" 2>/dev/null || true)" == 403 ]]; then
      return
    fi
    kill -0 "$pid" 2>/dev/null || break
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
echo "Evidence directory $work"
