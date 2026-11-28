#!/usr/bin/env bash
# Prepare the sole Fabric Weld artifact using the released SDK maintainer tool.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd -P)
sdk=${1:?Supply the absolute committed MedEx checkout}
evidence=$(realpath -m -- "${2:?Supply a new private preparation evidence directory}")
[[ "$sdk" == /* && -f "$sdk/tools/maintainer/mix.exs" ]]
cd "$root"
[[ ! -e .mix_sources.json && ! -L .mix_sources.json ]] || {
  echo 'Prepare uses the default genuine registry lock context.' >&2; exit 2;
}
test -z "$(git status --porcelain)"
source "$root/build_support/receipt_fixture.sh"
medex_receipt_fixture "$sdk/core/med_core/test/fixtures/receipt_vectors_v2.json"
test -f core/store/priv/sql/001_schema_v2.sql
test -f apps/exam/priv/static/acquisition.js
test -f apps/exam/priv/static/exam.js
mkdir -m 0700 -- "$evidence"
exec > >(tee "$evidence/prepare.log") 2>&1
trap 'printf "%s\n" "$?" > "$evidence/exit-status"' EXIT
unset MIX_ENV MIX_EXS MIX_TARGET MIX_DEPS_PATH MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT
cd "$sdk/tools/maintainer"
mix weld help project
mix weld help prepare
manifest="$root/build_support/weld.exs"
mix weld setup --manifest "$manifest"
mix weld plan --manifest "$manifest" --artifact mf_exam --format json > "$evidence/plan.json"
mix weld project --manifest "$manifest" --artifact mf_exam --kind live
mix weld prepare --manifest "$manifest" --artifact mf_exam "${@:3}"
mix weld path --manifest "$manifest" --artifact mf_exam --kind bundle > "$evidence/bundle-path"
test -z "$(git -C "$root" status --porcelain)"
