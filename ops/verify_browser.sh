#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
umask 077

for tool in mix node uv openssl curl psql jq; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool. Run ./onboard.sh --integration." >&2; exit 1; }
done
[[ -d ops/browser/node_modules/playwright ]] || { echo "Run ./onboard.sh --integration." >&2; exit 1; }

mode="${1:-}"
[[ -z "$mode" || "$mode" == "--release" ]] || { echo "Usage: $0 [--release]" >&2; exit 1; }

mkdir -p _build
work="$(mktemp -d "$PWD/_build/browser.XXXXXXXX")"
export MF_EXAM_ID="exam-$(openssl rand -hex 8)"
export MF_LAB=1
export MF_HTTP_PORT="${MF_HTTP_PORT:-14000}"
export MF_LAB_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_SECRET_KEY_BASE="$(openssl rand -hex 48)"
export MF_FIXTURE_DIR="${MF_FIXTURE_DIR:-$PWD/_build/circor}"
export MF_ARTIFACT_DIR="$work/recordings"
export MF_SERVICE_STATE="${MF_SERVICE_STATE:-$work/services}"

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


bash apps/exam/deps/med_ex/priv/fixtures/prepare.sh "$MF_FIXTURE_DIR"

if [[ "$mode" == "--release" ]]; then
  (cd apps/exam && env -u MF_LAB MIX_ENV=prod mix release --overwrite) >"$work/release.log" 2>&1 ||
    { cat "$work/release.log" >&2; exit 1; }
fi

start_exam() {
  if [[ "$mode" == "--release" ]]; then
    (cd apps/exam && exec _build/prod/rel/mf_exam/bin/mf_exam start) >>"$work/exam.log" 2>&1 &
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
node ops/browser/check.mjs
stop_exam
start_exam
node ops/browser/check.mjs --after-restart
echo "Evidence directory $work"
