#!/usr/bin/env bash
# Exercise the unpublished SDK and its real consumer without publishing or tagging.
set -euo pipefail
cd "$(dirname "$0")/.."
fabric=$PWD
(
  cd ../med_ex
  ./onboard.sh
  mix ci
  mix monorepo.dialyzer
  node --test core/med_web/test/*.mjs
  mix weld.release.prepare
  mix weld.project
)
mix deps.get --check-locked
for project in core/domain core/store core/interop; do
  (cd "$project" && mix deps.get --check-locked && mix test && mix quality)
done
mix docs --warnings-as-errors
export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-$fabric/_build/playwright}"
(cd ops/browser && npm ci --ignore-scripts && ./node_modules/.bin/playwright install chromium)
(
  cd apps/exam
  export MF_MED_EX_PATH="$fabric/../med_ex/dist/monolith/med_ex"
  mkdir -p _build
  cp mix.lock _build/candidate.mix.lock
  mix deps.get
  mix hex.audit
  mix test
  mix quality
  bash ../../ops/verify_browser.sh --release
)
