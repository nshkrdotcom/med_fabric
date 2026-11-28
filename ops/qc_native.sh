#!/usr/bin/env bash
set -euo pipefail
umask 077
usage() {
  echo 'Usage: ops/qc_native.sh [--suite all|paired|soak] [--preview off|isolated] [--evidence NEW_DIR]'
  echo '       [--volume EXISTING_EXT4_DIR] [--artifacts MANIFEST.json] [--seconds N] [--keep-failure]'
  echo '       [--med-ex-project PROJECT_OR_V2_BUNDLE_OR_CURRENT] (short source diagnostics only)'
  echo '       [--preflight] (check exact release inputs/tools without starting services)'
  echo 'Soak defaults to 29 minutes. Use --suite soak --seconds 60 for a short diagnostic.'
  echo 'Default runs use locked Hex packages; candidate projects require --med-ex-project.'
}
suite=all
preflight=false
seconds=
volume=
candidate=
artifacts=
preview_mode=
evidence=
options=()
keep=0
while (( $# )); do
  case "$1" in
    --help) usage; exit 0 ;;
    --preflight) preflight=true; shift ;;
    --keep-failure) options=(--keep-failure); keep=1; shift ;;
    --evidence|--suite|--volume|--med-ex-project|--seconds|--preview|--artifacts)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
      case "$1" in
        --evidence) evidence=$(realpath -m -- "$2") ;;
        --suite) suite=$2 ;;
        --volume) volume=$(realpath -e -- "$2") ;;
        --med-ex-project) candidate=$(realpath -e -- "$2") ;;
        --artifacts) artifacts=$(realpath -e -- "$2") ;;
        --seconds) seconds=$2 ;;
        --preview) preview_mode=$2 ;;
      esac
      shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -z "$preview_mode" || "$preview_mode" == off || "$preview_mode" == isolated ]] || { usage >&2; exit 2; }
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
  echo 'The full release gate requires six exact Hex archives. Use paired or a short soak for source diagnostics.' >&2
  exit 2
fi
if [[ "$suite" == all && "$preview_mode" == off ]]; then
  echo 'The all suite requires isolated Preview; use --suite soak --preview off for the separate clean gate.' >&2
  exit 2
fi
if [[ -n "$candidate" && -n "$artifacts" ]]; then
  echo 'Choose exact installed archives or an explicit source diagnostic, never both.' >&2
  exit 2
fi
if [[ "$suite" == all || ( "$suite" == soak && "$seconds" == 1740 ) ]]; then
  [[ -n "$artifacts" && -f "$artifacts" ]] || {
    echo 'Full native and 1740-second soak gates require --artifacts with all six exact archive identities.' >&2
    exit 2
  }
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ ! -e .mix_sources.json && ! -L .mix_sources.json ]] || { echo 'Use an unselected checkout.' >&2; exit 2; }
if "$preflight"; then
  exec ./ops/qc_preflight.sh "$suite" "${preview_mode:-isolated}" "$artifacts" "$volume"
fi
if [[ "$suite" == all ]]; then
  source build_support/receipt_fixture.sh
  medex_receipt_fixture "$PWD/../med_ex/core/med_core/test/fixtures/receipt_vectors_v2.json"
fi
if [[ "$suite" != all ]]; then
  if [[ -z "$volume" ]]; then
    volume="$PWD/_build"
    mkdir -p -- "$volume"
  fi
fi
[[ -z "$volume" || -d "$volume" ]] || { echo 'Volume must be a directory.' >&2; exit 2; }
if [[ -n "$candidate" ]]; then
  if [[ -f "$candidate" && $(basename -- "$(dirname -- "$candidate")") == current ]]; then
    identity=$(jq -er 'select(.schema == "weld.current/2" and .artifact == "med_ex" and (keys == ["artifact","bundle_id","schema"])) | .bundle_id | select(test("^[0-9a-f]{64}$"))' "$candidate") ||
      { echo 'Invalid Weld v2 current pointer.' >&2; exit 2; }
    candidate="$(dirname -- "$(dirname -- "$candidate")")/bundles/med_ex/$identity/project"
  elif [[ -f "$candidate/bundle.json" ]]; then
    candidate="$candidate/project"
  fi
  [[ -f "$candidate/mix.exs" ]] || { echo 'Select a Mix project or a Weld release directory.' >&2; exit 2; }
fi

if [[ -z "$evidence" ]]; then
  evidence=$(mktemp -d -- "${TMPDIR:-/tmp}/fabric-$suite.XXXXXXXX")
else
  mkdir -- "$evidence"
fi
trap 'status=$?; if [[ -n "$candidate" ]]; then rm -f -- .mix_sources.json; fi; printf "%s\n" "$status" > "$evidence/exit-status"' EXIT
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
  if [[ "$suite" == soak && "$(findmnt -T "$lab" -no FSTYPE)" != ext4 ]]; then
    echo 'Soak qualification requires an actual ext4 filesystem; choose --volume on ext4.' >&2
    exit 2
  fi
fi
if [[ -n "$candidate" ]]; then
  printf 'MedEx project: %s\n' "$candidate"
  jq -cn --arg path "$candidate" '{med_ex:{path:$path}}' > .mix_sources.json
  bundle=$(dirname -- "$candidate")
  if [[ -f "$bundle/bundle.json" ]]; then
    cp "$bundle/bundle.json" "$evidence/med-ex-bundle.json"
    for record in inventory qualification; do
      if [[ -f "$bundle/$record.json" ]]; then
        cp "$bundle/$record.json" "$evidence/med-ex-$record.json"
      fi
    done
  fi
fi

phase_started=$SECONDS
if [[ -n "$artifacts" ]]; then
  source ops/detached_consumers.sh
  mkdir -m 0700 -- "$evidence/installed"
  prepare_detached_consumers "$PWD" "$artifacts" "$evidence/consumers" "$evidence/installed"
  args+=(--installed-consumers "$evidence/consumers")
  printf 'Detached consumers ready (%ss)\n' "$((SECONDS-phase_started))"
fi
phase_started=$SECONDS

if [[ "$suite" != soak || "$preview_mode" == isolated ]]; then
  # Keep the browser install private to the checkout and keyed to the committed lock.
  lock_digest=$(sha256sum ops/package-lock.json | cut -d' ' -f1)
  if [[ ! -f ops/node_modules/.fabric-lock-sha256 ||
        "$(cat ops/node_modules/.fabric-lock-sha256)" != "$lock_digest" ]]; then
    (cd ops && npm ci && printf '%s\n' "$lock_digest" > node_modules/.fabric-lock-sha256)
  fi
  (cd ops && node -e 'const {chromium}=require("playwright");(async()=>{const b=await chromium.launch();await b.close()})().catch(e=>{console.error(e);process.exit(1)})') ||
    (cd ops && npx playwright install chromium)
  printf 'Browser prerequisites ready (%ss)\n' "$((SECONDS-phase_started))"
fi

if [[ "$suite" != all ]]; then
  apps=(exam handheld)
  preview=${preview_mode:-off}
  if [[ "$suite" == paired || "$preview" == isolated ]]; then
    apps+=(preview)
    preview=isolated
  fi
  if [[ "$suite" == soak ]]; then args+=(--seconds "$seconds"); fi

  if [[ -z "$artifacts" ]]; then
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
  fi

  elixir ops/handheld_acceptance.exs --suite "$suite" --preview "$preview" \
    --report "$evidence/native.json" "${args[@]}"
  if [[ "$suite" == paired ]]; then
    jq -e --arg suite paired -f ops/verify_native_report.jq "$evidence/native.json"
  elif [[ "$seconds" == 1740 ]]; then
    jq -e --arg preview "$preview" -f ops/verify_soak_report.jq "$evidence/native.json"
  fi
  printf 'Qualification evidence: %s\n' "$evidence"
  exit 0
fi

printf 'Receipt corpus SHA-256: %s\n' "$(sha256sum "$MEDEX_RECEIPT_VECTORS" | cut -d' ' -f1)"

phase_started=$SECONDS
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

printf 'Source integration inputs ready (%ss)\n' "$((SECONDS-phase_started))"
phase_started=$SECONDS
elixir ops/handheld/oracle_test.exs
elixir ops/handheld/process_lab_test.exs
elixir ops/handheld/soak_test.exs
printf 'Native harness tests passed (%ss)\n' "$((SECONDS-phase_started))"
phase_started=$SECONDS
ops/qc_services.sh run "${options[@]}" -- bash -euc '
  evidence=$1
  phase_started=$SECONDS
  (cd apps/exam && mix test integration/{device_review,device_root_lock,preview_isolation,outbox,ingress_bounds,background_isolation}_test.exs --warnings-as-errors)
  printf "Exam integration passed (%ss)\n" "$((SECONDS-phase_started))"
  phase_started=$SECONDS
  timeout --signal=TERM --kill-after=30s 1600s elixir ops/handheld_acceptance.exs \
    --suite all --preview isolated --fhir hapi --report "$evidence/native.json" "${@:2}"
  jq -e -f ops/verify_native_report.jq "$evidence/native.json"
  printf "Native acceptance passed (%ss)\n" "$((SECONDS-phase_started))"
  phase_started=$SECONDS
  # This verifier includes Store, Interop, and Exam recording/encounter integration.
  export MF_HTTP_PORT=$(elixir -e '\''{:ok,s}=:gen_tcp.listen(0,ip: {127,0,0,1}); {:ok,{_,p}}=:inet.sockname(s); IO.write(p); :gen_tcp.close(s)'\'')
  timeout --signal=TERM --kill-after=30s 460s ops/verify_browser.sh --release \
    --installed-consumers "$evidence/consumers"
  printf "Browser release verification passed (%ss)\n" "$((SECONDS-phase_started))"
' qc "$evidence" "${args[@]}"
printf 'Native services phase complete (%ss)\n' "$((SECONDS-phase_started))"
phase_started=$SECONDS
MF_QC_KEEP_FAILURE=$keep timeout --signal=TERM --kill-after=30s 900s ops/qc_detached_release.sh \
  "$evidence/detached.json" --artifacts "$artifacts" --native-evidence "$evidence"
printf 'Detached release phase complete (%ss)\n' "$((SECONDS-phase_started))"
printf 'Native and detached qualification reports at %s\n' "$evidence"
