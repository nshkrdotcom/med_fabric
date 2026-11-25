#!/usr/bin/env bash
# Loaded by qc_fabric_sources.sh. Keep same absolute paths on reuse because
# dependency sources, compiler manifests and BEAM debug info can contain them.

lane_digest() (
  cd "$1"
  {
    find . -type f ! -path ./.lane-receipt -print0 | sort -z | xargs -0 -r sha256sum
    find . ! -path ./.lane-receipt -printf '%P\t%y\t%m\t%l\0' | sort -z
  } | sha256sum | cut -d' ' -f1
)

open_lane_cache() {
  umask 077
  [[ ${MF_SOURCE_QC_CACHE:?Set MF_SOURCE_QC_CACHE to an absolute private directory.} == /* ]]
  [[ ! -L "$MF_SOURCE_QC_CACHE" ]]
  cache=$(realpath -m -- "$MF_SOURCE_QC_CACHE")
  mkdir -- "$cache" 2>/dev/null || [[ -d "$cache" ]]
  [[ -O "$cache" && ! -L "$cache" && $(stat -c %a "$cache") == 700 ]]
  local setup_lock
  exec {setup_lock}<"$cache"
  flock "$setup_lock"
  if [[ ! -e "$cache/.owner" && ! -L "$cache/.owner" ]]; then
    [[ -z $(find "$cache" -mindepth 1 -maxdepth 1 -print -quit) ]] ||
      { echo "Refusing to initialize a nonempty unmarked source lane cache." >&2; return 1; }
    printf 'med-fabric-source-lanes/v1\n' > "$cache/.owner"
  fi
  [[ -f "$cache/.owner" && ! -L "$cache/.owner" ]]
  [[ $(cat "$cache/.owner") == med-fabric-source-lanes/v1 ]]
  exec {setup_lock}<&-
}

lock_lane() {
  [[ $key =~ ^[a-f0-9]{64}$ && ! -L "$cache/$key.lock" ]]
  exec {lane_lock}>"$cache/$key.lock"
  flock "$lane_lock"
  entry="$cache/$key"
  [[ ! -L "$entry" ]]
}

reuse_lane() {
  open_lane_cache
  local identities
  identities=$(elixir -r "$repo/config/sources.exs" -e '
    selector = JSON.decode!(System.fetch_env!("MED_EX_SOURCE"))
    if Enum.any?(selector, fn {_, choice} -> Map.has_key?(choice, "git") end) do
      raise "Use github coordinates or --no-cache for a raw Git URL"
    end

    IO.puts(MedFabric.BuildSources.build_identity())
    IO.puts(MedFabric.BuildSources.registry_identity())
  ')
  key=$(printf '%s\n%s\n%s\n' "$identities" "$(lane_digest "$scratch")" "$MED_EX_SOURCE" |
    sha256sum | cut -d' ' -f1)
  lock_lane
  if [[ -f "$entry/.lane-receipt" && ! -L "$entry/.lane-receipt" ]] &&
    [[ $(cat "$entry/.lane-receipt") == "$(lane_digest "$entry")" ]]; then
    rm -rf -- "$scratch"
    printf 'Source lane cache hit %s\n' "$key"
  else
    if [[ -e "$entry" ]]; then
      echo "Invalid or interrupted source lane cache $key. Rebuilding." >&2
      rm -rf -- "$entry"
    fi
    mkdir -- "$entry"
    cp -a "$scratch/." "$entry/"
    rm -rf -- "$scratch"
    printf 'Source lane cache miss %s\n' "$key"
  fi
  scratch=$entry
  persistent=true
  rm -f -- "$scratch/.lane-receipt"
}

prune_lane() {
  open_lane_cache
  key=$1
  lock_lane
  if [[ -d "$entry" ]]; then
    rm -rf -- "$entry"
    printf 'Removed private source lane %s\n' "$key"
  fi
}
