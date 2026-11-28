#!/usr/bin/env bash
set -euo pipefail
umask 077
# Wait in the foreground shell so terminal signals reach its traps promptly.
if [[ ${1:-} != --worker ]]; then
  setsid bash "$0" --worker &
  worker=$!
  trap 'kill -TERM -- "-$worker" 2>/dev/null || true; exit 130' INT
  trap 'kill -TERM -- "-$worker" 2>/dev/null || true; exit 143' TERM
  wait "$worker"
  exit
fi
fab=$(cd "$(dirname "$0")/.." && pwd -P)
sdk=$(cd "$fab/../med_ex" && pwd -P)
run=$(mktemp -d /tmp/soak.XXXXXXXX)
out="$run/candidates"
qc="$run/qualification"
log="$run/live.log"
mkdir "$qc"
touch "$log"
printf 'tail -F %q\n' "$log"

trap 'exit 143' TERM
trap 'status=$?; if (( status != 0 )); then printf "Soak stopped (%s). See %s\n" "$status" "$log" >&3; else printf "Soak passed. Full log: %s\n" "$log" >&3; fi' EXIT
exec 3>&2 > >(tee -a "$log") 2>&1
export PATH="$(pg_config --bindir):$PATH"
# Fallback for the owned, private coturn installation retained on the original QC host.
tools_dir=/tmp/med-release-qc.6XQST7
if ! command -v turnserver >/dev/null && [[ ! -L "$tools_dir" && -O "$tools_dir" &&
    $(stat -c %a "$tools_dir") == 700 && -x "$tools_dir/native-tools/bin/turnserver" ]]; then
  export PATH="$tools_dir/native-tools/bin:$PATH"
fi
command -v turnserver >/dev/null || { echo "Put the installed turnserver on PATH." >&2; exit 2; }
export MED_EX_OPUS_TARBALL="${MED_EX_OPUS_TARBALL:-${XDG_CACHE_HOME:-$HOME/.cache}/med_ex_opus/opus-1.5.2.tar.gz}"
export MEDEX_RECEIPT_VECTORS="$sdk/core/med_core/test/fixtures/receipt_vectors_v2.json"
[[ -r "$MED_EX_OPUS_TARBALL" ]] || { echo "Set MED_EX_OPUS_TARBALL to the pinned Opus archive." >&2; exit 2; }
volume_base=${SOAK_EXT4_BASE:-/var/tmp}
test "$(findmnt -T "$volume_base" -no FSTYPE)" = ext4
volume=$(mktemp -d "$volume_base/med-soak.XXXXXXXX")
printf '%s\n' "$volume" > "$qc/soak-volume-path"
printf 'Private labs %s\n' "$volume"

cd "$sdk"
# Fail fast on projected doc links and boundary invariants before candidate builds.
elixir "$fab/ops/check_hardening.exs"
# The ecosystem runner writes gate output to files while it runs.
tail -q -n +1 -F -- "$out/source-qc/medex-core.log" "$out/source-qc/medex-prepare.log" \
  "$out/sync.log" "$out/build.log" >>"$log" 2>/dev/null &
log_reader=$!
trap 'status=$?; kill "$log_reader" 2>/dev/null || true; wait "$log_reader" 2>/dev/null || true; if (( status != 0 )); then printf "Soak stopped (%s). See %s\n" "$status" "$log" >&3; else printf "Soak passed. Full log: %s\n" "$log" >&3; fi' EXIT
build_support/prepare_candidates.sh sync "$out"
locks=(core/domain/mix.lock core/store/mix.lock apps/exam/mix.lock
       apps/handheld/mix.lock apps/preview/mix.lock)
sha256sum -c "$out/upstream-locks.sha256"
git -C "$fab" diff --check
git -C "$fab" diff --stat -- "${locks[@]}"
if ! git -C "$fab" diff --quiet -- "${locks[@]}"; then
  git -C "$fab" commit --only -m "Lock verified upstream soak candidates" -- "${locks[@]}"
fi
build_support/prepare_candidates.sh build "$out"
manifest="$out/candidate-inputs.json"
jq -e '.packages | length == 6' "$manifest"
jq -r '.packages | to_entries[] | [.key,.value.source_revision,.value.sha256] | @tsv' "$manifest"

build_support/check_consumers.sh --registry \
  --registry-manifest "$manifest" \
  --registry-lock "$sdk/tools/maintainer/mix.lock" \
  --registry-lock "$fab/tools/maintainer/mix.lock" \
  --registry-lock "$fab/mix.lock" \
  --evidence "$qc/registry" -- \
  bash -euo pipefail -c '
    cd "$1"
    manifest=$2
    qc=$3
    volume=$4
    ops/qc_native.sh --preflight --suite soak --preview isolated \
      --artifacts "$manifest" --volume "$volume"
    MIX_ENV=dev mix deps.get --check-locked
    MIX_ENV=dev mix compile --warnings-as-errors
    for mode in off isolated; do
      ops/qc_native.sh --suite soak --seconds 1740 --preview "$mode" \
        --artifacts "$manifest" --volume "$volume" --evidence "$qc/soak-$mode"
    done
  ' soak "$fab" "$manifest" "$qc" "$volume"
