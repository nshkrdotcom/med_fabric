#!/usr/bin/env bash
set -euo pipefail
umask 077
usage() {
  echo 'Usage: ops/qc_native.sh [--suite all|paired|soak] [--evidence NEW_DIR]'
  echo '       [--volume EXISTING_DIR] [--med-ex-project PROJECT_OR_WELD_RELEASE_DIR] [--seconds N] [--keep-failure]'
  echo 'Soak defaults to 29 minutes. Use --suite soak --seconds 60 for a short diagnostic.'
  echo 'Default runs use locked Hex packages; candidate projects require --med-ex-project.'
}
suite=all
seconds=
volume=
candidate=
evidence=
options=()
keep=0
while (( $# )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --keep-failure) options=(--keep-failure); keep=1; shift ;;
    --evidence|--suite|--volume|--med-ex-project|--seconds)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in
        --evidence) evidence=$(realpath -m -- "$2") ;;
        --suite) suite=$2 ;;
        --volume) volume=$(realpath -e -- "$2") ;;
        --med-ex-project) candidate=$(realpath -e -- "$2") ;;
        --seconds) seconds=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ "$suite" =~ ^(all|paired|soak)$ ]] || { usage >&2; exit 2; }
if [[ "$suite" == soak ]]; then
  seconds=${seconds:-1740}
  [[ "$seconds" =~ ^[1-9][0-9]{0,3}$ ]] && (( seconds >= 3 && seconds <= 1740 )) ||
    { echo 'Use a soak duration between 3 and 1740 seconds.' >&2; exit 2; }
elif [[ -n "$seconds" ]]; then
  echo '--seconds applies only to the soak suite.' >&2
  exit 2
fi
if [[ "$suite" == all && -n "$candidate" ]]; then
  echo 'The full release gate requires locked Hex packages. Use paired or soak for a prepared project.' >&2
  exit 2
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ ! -e .mix_sources.json && ! -L .mix_sources.json ]] || { echo 'Use an unselected checkout.' >&2; exit 2; }
if [[ "$suite" != all ]]; then
  if [[ -z "$volume" ]]; then
    volume="$PWD/_build"
    mkdir -p -- "$volume"
  fi
fi
[[ -z "$volume" || -d "$volume" ]] || { echo 'Volume must be a directory.' >&2; exit 2; }
if [[ -n "$candidate" ]]; then
  if [[ ! -f "$candidate/mix.exs" && -f "$candidate/CURRENT" ]]; then
    read -r schema identity rest < "$candidate/CURRENT"
    [[ "$schema" == weld.release/v1 && "$identity" =~ ^[0-9a-f]{64}$ && -z "$rest" ]] ||
      { echo 'Invalid Weld CURRENT pointer.' >&2; exit 2; }
    candidate="$candidate/$identity/project"
  fi
  [[ -f "$candidate/mix.exs" ]] || { echo 'Select a Mix project or a Weld release directory.' >&2; exit 2; }
fi

if [[ -z "$evidence" ]]; then
  evidence=$(mktemp -d -- "${TMPDIR:-/tmp}/fabric-$suite.XXXXXXXX")
else
  mkdir -- "$evidence"
fi
trap 'status=$?; printf "%s\n" "$status" > "$evidence/exit-status"' EXIT
exec > >(tee "$evidence/run.log") 2>&1
printf 'Evidence: %s\n' "$evidence"
unset MIX_ENV MIX_TARGET MIX_EXS MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE
while read -r name; do unset "$name"; done < <(compgen -e MF_)
export PATH="$(pg_config --bindir):$PATH"
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4 +SDcpu 2 +SDio 2}"

args=()
if [[ -n "$volume" ]]; then
  lab=$(mktemp -d -- "$volume/fabric-$suite.XXXXXXXX")
  args+=(--run-dir "$lab")
  printf 'Private lab: %s\n' "$lab"
  findmnt -T "$lab" -no FSTYPE,OPTIONS > "$evidence/filesystem.txt"
fi
if [[ -n "$candidate" ]]; then
  printf 'MedEx project: %s\n' "$candidate"
  export MF_MED_EX_PATH="$candidate"
  if [[ -f "$candidate/weld.provenance.json" ]]; then
    cp "$candidate/weld.provenance.json" "$evidence/med-ex-provenance.json"
    release=$(dirname -- "$candidate")/release.json
    if [[ -f "$release" ]]; then
      jq '{identity, source_revision, content_sha256, weld_version}' "$release" > "$evidence/med-ex-release.json"
    fi
  fi
fi

if [[ "$suite" != soak ]]; then
  # Keep the browser install private to the checkout and keyed to the committed lock.
  lock_digest=$(sha256sum ops/package-lock.json | cut -d' ' -f1)
  if [[ ! -f ops/node_modules/.fabric-lock-sha256 ||
        "$(cat ops/node_modules/.fabric-lock-sha256)" != "$lock_digest" ]]; then
    (cd ops && npm ci && printf '%s\n' "$lock_digest" > node_modules/.fabric-lock-sha256)
  fi
  (cd ops && node -e 'const {chromium}=require("playwright");(async()=>{const b=await chromium.launch();await b.close()})().catch(e=>{console.error(e);process.exit(1)})') ||
    (cd ops && npx playwright install chromium)
fi

if [[ "$suite" != all ]]; then
  apps=(exam handheld)
  preview=off
  if [[ "$suite" == paired ]]; then
    apps+=(preview)
    preview=isolated
  else
    args+=(--seconds "$seconds")
  fi

  for app in "${apps[@]}"; do
    (
      cd "apps/$app"
      export MF_SOURCE_QC_PROFILE="$app"
      if [[ -z "$candidate" ]]; then
        export MF_SOURCE_QC_EXPECT_DEFAULT=1
        mix deps.get --check-locked
      else
        mix deps.get
        mix deps.get --check-locked
      fi
      mix compile --warnings-as-errors
      mix run --no-start ../../ops/prove_fabric_sources.exs
    )
  done

  elixir ops/handheld_acceptance.exs --suite "$suite" --preview "$preview" \
    --report "$evidence/native.json" "${args[@]}"
  if [[ "$suite" == paired ]]; then
    jq -e --arg suite paired -f ops/verify_native_report.jq "$evidence/native.json"
  fi
  printf 'Qualification evidence: %s\n' "$evidence"
  exit 0
fi

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
elixir ops/handheld/soak_test.exs
ops/qc_services.sh run "${options[@]}" -- bash -euc '
  evidence=$1
  (cd apps/exam && mix test integration/{device_review,device_root_lock,preview_isolation}_test.exs)
  timeout --signal=TERM --kill-after=30s 1600s elixir ops/handheld_acceptance.exs \
    --suite all --preview isolated --fhir hapi --report "$evidence/native.json" "${@:2}"
  jq -e -f ops/verify_native_report.jq "$evidence/native.json"
  # This verifier includes Store, Interop, and Exam recording/encounter integration.
  export MF_HTTP_PORT=$(elixir -e '\''{:ok,s}=:gen_tcp.listen(0,ip: {127,0,0,1}); {:ok,{_,p}}=:inet.sockname(s); IO.write(p); :gen_tcp.close(s)'\'')
  timeout --signal=TERM --kill-after=30s 460s ops/verify_browser.sh --release
' qc "$evidence" "${args[@]}"
MF_QC_KEEP_FAILURE=$keep timeout --signal=TERM --kill-after=30s 900s ops/qc_detached_release.sh "$evidence/detached.json"
printf 'Native and detached qualification reports at %s\n' "$evidence"
