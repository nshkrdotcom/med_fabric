#!/usr/bin/env bash
# Exercise the unpublished SDK and its real consumer without publishing or tagging.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fabric=$PWD
sdk="$(cd ../med_ex && pwd)"
[[ $# == 0 ]] || { echo "Usage: $0" >&2; exit 2; }
# Each project owns its build/lock roots; the verifier enables its own lab later.
unset MIX_ENV MIX_EXS MIX_DEPS_PATH MIX_BUILD_PATH MIX_LOCKFILE MF_LAB MF_MED_EX_PATH

for tool in node npm cmp; do
  command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
[[ "$(node --version)" == "v24.19.0" ]] || {
  echo "Activate Node 24.19.0 from .tool-versions." >&2; exit 1;
}

mkdir -p _build
candidate_pointer="$(mktemp "$fabric/_build/med-ex-candidate.XXXXXXXX")"
trap 'rm -f "$candidate_pointer"' EXIT

(
  cd "$sdk"
  ./onboard.sh
  mix ci
  mix monorepo.dialyzer
  node --test core/med_rtc/test/*.mjs
  # Use Weld's returned project path, never a stale projection or a log glob.
  MF_CANDIDATE_POINTER="$candidate_pointer" mix run --no-start -e '
    result = Weld.release_prepare!("build_support/weld.exs", artifact: "med_ex")
    File.write!(System.fetch_env!("MF_CANDIDATE_POINTER"),
      Path.expand(result.project_path) <> "\n")
  '
)
IFS= read -r MF_MED_EX_PATH < "$candidate_pointer"
export MF_MED_EX_PATH
[[ -f "$MF_MED_EX_PATH/mix.exs" ]] || { echo "Missing prepared SDK project" >&2; exit 1; }
printf 'Prepared SDK candidate: %s\n' "$MF_MED_EX_PATH"
for asset in session_hook.js pcm_capture.js pcm_worklet.js; do
  cmp "$sdk/core/med_rtc/priv/static/med_web/$asset" \
    "$MF_MED_EX_PATH/priv/static/med_web/$asset"
done

mix deps.get --check-locked
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer --force-check
for project in core/domain core/store core/interop; do
  (
    cd "$project"
    mix deps.get --check-locked
    mix format --check-formatted
    MIX_ENV=test mix compile --warnings-as-errors
    mix test
    mix quality
  )
done
mix docs --warnings-as-errors
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$fabric/_build/playwright}"
(cd ops/browser && npm ci --ignore-scripts && ./node_modules/.bin/playwright install chromium)
(
  cd apps/exam
  mkdir -p _build
  # Resolve the path dependency in a disposable lock; retain the Hex lock.
  cp mix.lock _build/candidate.mix.lock
  mix deps.get
  mix hex.audit
  mix format --check-formatted
  MIX_ENV=test mix compile --warnings-as-errors
  mix test
  mix quality
  bash ../../ops/verify_browser.sh --release
)
