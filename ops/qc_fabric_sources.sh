#!/usr/bin/env bash
# Resolve and compile the actual app projects, not substitutes. Work on a
# disposable source-only copy, leaving original selectors and locks untouched.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
source "$repo/ops/source_lane_cache.sh"
if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: MED_EX_SOURCE=JSON [MF_SOURCE_QC_CACHE=/private/root] ops/qc_fabric_sources.sh [--no-cache]'
  printf '%s\n' '       MF_SOURCE_QC_CACHE=/private/root ops/qc_fabric_sources.sh --prune SHA256'
  exit 0
fi
if [[ ${1:-} == --prune && $# == 2 ]]; then prune_lane "$2"; exit 0; fi
if [[ ${1:-} == --no-cache ]]; then unset MF_SOURCE_QC_CACHE; shift; fi
[[ $# == 0 ]]
: "${MED_EX_SOURCE:?Supply an absolute-path, pinned Git, or versioned Hex family object}"
command -v mix >/dev/null || { echo 'Elixir 1.20 and Mix are required.' >&2; exit 127; }
command -v elixir >/dev/null
umask 077
scratch=$(mktemp -d)
persistent=false
cleanup() {
  local rc=$?
  trap - EXIT
  rm -f -- "$scratch/.mix_sources.json"
  if "$persistent"; then
    if ((rc == 0)); then
      local receipt
      receipt=$(mktemp "$cache/.receipt.XXXXXXXX")
      lane_digest "$scratch" > "$receipt"
      mv -T -- "$receipt" "$scratch/.lane-receipt"
    fi
  else
    rm -rf -- "$scratch"
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS
export MIX_ENV=test
# Do not copy runtime state or ignored selectors/credentials from the real apps.
# Use only the source directories and named project/build files.
for project in core/domain core/store core/interop apps/exam apps/handheld apps/preview; do
  mkdir -p "$scratch/$project"
  for name in VERSION mix.exs mix.lock .formatter.exs .credo.exs .dialyzer_ignore.exs lib config priv assets build_support test integration README.md; do
    if [[ -e "$repo/$project/$name" ]]; then
      tar -C "$repo/$project" --exclude=node_modules --exclude=_build --exclude=deps --exclude=.git \
        --exclude=.mix_sources.json --exclude='*.credential' --exclude='*.key' --exclude=.env \
        -cf - "$name" | tar -C "$scratch/$project" -xf -
    fi
  done
done
mkdir -p "$scratch/config"
cp "$repo/config/sources.exs" "$scratch/config/"
cp "$repo/VERSION" "$scratch/"
# The root is not a dependency, but retain its baseline lock for the audit.
cp "$repo/mix.lock" "$scratch/"
if [[ -n ${MF_SOURCE_QC_CACHE:-} ]]; then reuse_lane; fi
(cd "$scratch" && sha256sum mix.lock {core,apps}/*/mix.lock) > "$scratch/baseline-locks"
probe() {
  local project=$1
  (cd "$scratch/$project" && elixir -e '
    Mix.start()
    Mix.Project.in_project(:source_qc_probe, ".", [], fn _ ->
      config = Mix.Project.config()
      apps = Enum.map(config[:deps], &elem(&1, 0))
      IO.inspect({config[:app], apps, Keyword.take(config, [:lockfile, :deps_path, :build_path])}, limit: :infinity)
    end)')
}
for app in exam handheld preview; do probe "apps/$app" > "$scratch/$app-before"; done
for app in exam handheld preview; do
  if grep -q '/source_contexts/' "$scratch/$app-before"; then echo "Unexpected default context: $app" >&2; exit 1; fi
done
printf '%s\n' "$MED_EX_SOURCE" > "$scratch/.mix_sources.json"
for app in exam handheld preview; do
  (
    cd "$scratch/apps/$app"
    export MF_SOURCE_QC_PROFILE=$app
    mix deps.get
    mix deps.tree
    mix compile --warnings-as-errors
    mix run --no-start "$repo/ops/prove_fabric_sources.exs"
  )
done

rm "$scratch/.mix_sources.json"
for app in exam handheld preview; do probe "apps/$app" > "$scratch/$app-after"; cmp "$scratch/$app-before" "$scratch/$app-after"; done
(cd "$scratch" && sha256sum --check baseline-locks)
echo 'Actual Fabric source selection, removal/restoration and default locks passed.'
