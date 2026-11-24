#!/usr/bin/env bash
# Resolve and compile the actual app projects, not substitutes. Work on a
# disposable source-only copy, leaving original selectors and locks untouched.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
: "${MED_EX_SOURCE:?Supply an absolute-path, pinned Git, or versioned Hex family object}"
command -v mix >/dev/null || { echo 'Elixir 1.20 and Mix are required.' >&2; exit 127; }
command -v elixir >/dev/null
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
unset MF_MED_EX_PATH MF_EXAM_LEGACY_MEDIA MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS
export MIX_ENV=test
# Do not copy runtime state or ignored selectors/credentials from the real apps.
# Use only the source directories and named project/build files.
for project in core/domain core/store core/interop apps/exam apps/handheld apps/preview; do
  mkdir -p "$scratch/$project"
  for name in mix.exs mix.lock .formatter.exs .credo.exs .dialyzer_ignore.exs lib config priv assets build_support test integration README.md; do
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
(cd "$scratch" && find . -name mix.lock -type f -print0 | sort -z | xargs -0 sha256sum) > "$scratch/baseline-locks"
probe() {
  local project=$1
  (cd "$scratch/$project" && elixir -e '
    Mix.start()
    Mix.Project.in_project(:source_qc_probe, ".", [], fn _ ->
      config = Mix.Project.config()
      IO.inspect({config[:app], config[:deps], Keyword.take(config, [:lockfile, :deps_path, :build_path])}, limit: :infinity)
    end)')
}
for app in exam handheld preview; do probe "apps/$app" > "$scratch/$app-before"; done
MF_EXAM_LEGACY_MEDIA=1 probe apps/exam > "$scratch/legacy-before"
grep -q '/source_contexts/' "$scratch/legacy-before"
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
(
  cd "$scratch/apps/exam"
  export MF_EXAM_LEGACY_MEDIA=1 MF_SOURCE_QC_PROFILE=legacy-exam
  mix deps.get
  mix deps.tree
  mix compile --warnings-as-errors
  mix run --no-start "$repo/ops/prove_fabric_sources.exs"
)
rm "$scratch/.mix_sources.json"
for app in exam handheld preview; do probe "apps/$app" > "$scratch/$app-after"; cmp "$scratch/$app-before" "$scratch/$app-after"; done
MF_EXAM_LEGACY_MEDIA=1 probe apps/exam > "$scratch/legacy-after"
cmp "$scratch/legacy-before" "$scratch/legacy-after"
(cd "$scratch" && sha256sum --check baseline-locks)
echo 'Actual Fabric source/profile selection, removal/restoration and default locks passed.'
