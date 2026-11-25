#!/usr/bin/env bash
set -euo pipefail
umask 077
usage() { echo 'Usage: ops/qc_native.sh --evidence NEW_DIR [--keep-failure]'; }
if [[ ${1:-} == --help ]]; then usage; exit 0; fi
[[ $# -ge 2 && $1 == --evidence ]] || { usage >&2; exit 2; }
evidence=$(realpath -m -- "$2")
shift 2
options=()
keep=0
if [[ ${1:-} == --keep-failure ]]; then options=(--keep-failure); keep=1; shift; fi
[[ $# == 0 ]] || { usage >&2; exit 2; }

cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ ! -e .mix_sources.json && ! -L .mix_sources.json ]] || { echo 'Use an unselected default checkout.' >&2; exit 2; }
mkdir -- "$evidence"
unset MIX_ENV MIX_TARGET MIX_EXS MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE
while read -r name; do unset "$name"; done < <(compgen -e MF_)
export PATH="$(pg_config --bindir):$PATH"
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4 +SDcpu 2 +SDio 2}"

# Keep the browser install private to the checkout and keyed to the committed lock.
lock_digest=$(sha256sum ops/package-lock.json | cut -d' ' -f1)
if [[ ! -f ops/node_modules/.fabric-lock-sha256 ||
      "$(cat ops/node_modules/.fabric-lock-sha256)" != "$lock_digest" ]]; then
  (cd ops && npm ci && printf '%s\n' "$lock_digest" > node_modules/.fabric-lock-sha256)
fi
(cd ops && node -e 'const {chromium}=require("playwright");(async()=>{const b=await chromium.launch();await b.close()})().catch(e=>{console.error(e);process.exit(1)})') ||
  (cd ops && npx playwright install chromium)

for project in core/store core/interop; do
  (cd "$project" && MIX_ENV=test mix deps.get --check-locked)
done
for app in exam handheld preview; do
  (
    cd "apps/$app"
    export MIX_ENV=test MF_SOURCE_QC_EXPECT_DEFAULT=1 MF_SOURCE_QC_PROFILE="$app"
    mix deps.get --check-locked
    mix compile --warnings-as-errors
    mix run --no-start ../../ops/prove_fabric_sources.exs
  )
done
(
  cd apps/exam
  export MF_EXAM_LEGACY_MEDIA=1 MF_SOURCE_QC_PROFILE=legacy-exam
  for env in dev test; do
    export MIX_ENV=$env
    mix deps.get
    mix deps.get --check-locked
    mix compile --warnings-as-errors
    mix run --no-start ../../ops/prove_fabric_sources.exs
  done
)
elixir ops/handheld/oracle_test.exs
elixir ops/handheld/process_lab_test.exs
ops/qc_services.sh run "${options[@]}" -- bash -euc '
  evidence=$1
  (cd apps/exam && mix test integration/{device_review,device_root_lock}_test.exs)
  timeout --signal=TERM --kill-after=30s 1600s elixir ops/handheld_acceptance.exs \
    --suite all --preview isolated --fhir hapi --report "$evidence/native.json"
  jq -e -f ops/verify_native_report.jq "$evidence/native.json"
  # This verifier includes Store, Interop, and Exam recording/encounter integration.
  export MF_HTTP_PORT=$(elixir -e '\''{:ok,s}=:gen_tcp.listen(0,ip: {127,0,0,1}); {:ok,{_,p}}=:inet.sockname(s); IO.write(p); :gen_tcp.close(s)'\'')
  timeout --signal=TERM --kill-after=30s 460s ops/verify_browser.sh --release
' qc "$evidence"
MF_QC_KEEP_FAILURE=$keep timeout --signal=TERM --kill-after=30s 900s ops/qc_detached_release.sh "$evidence/detached.json"
printf 'Native and detached qualification reports at %s\n' "$evidence"
