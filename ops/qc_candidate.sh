#!/usr/bin/env bash
# Exercise the unpublished SDK and its real consumer without publishing or tagging.
set -euo pipefail
cd "$(dirname "$0")/.."
fabric=$PWD
registry=${MWO_REGISTRY:-"${XDG_CONFIG_HOME:-$HOME/.config}/mix_workspace_ops/medical/registry.json"}
mwo=${MWO_BIN:-$(command -v mix_workspace_ops || true)}
mwo=${mwo:-"$fabric/../mix_workspace_ops/mix_workspace_ops"}
[[ -x "$mwo" && -f "$registry" ]] || { echo "Set MWO_BIN and MWO_REGISTRY (see guides/browser_to_record.md)" >&2; exit 1; }
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
"$mwo" run --project med_fabric.mf_exam --mode local --registry "$registry" \
  --checkout-root "$fabric/.." --timeout 45m -- bash -ec '
    mix deps.get
    mix hex.audit
    mix test
    mix quality
    exec bash ../../ops/verify_browser.sh --release
  '
