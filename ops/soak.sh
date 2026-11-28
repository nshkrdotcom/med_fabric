#!/usr/bin/env bash
set -euo pipefail
umask 077
fab=$(cd "$(dirname "$0")/.." && pwd -P)
sdk=$(cd "$fab/../med_ex" && pwd -P)
run=$(mktemp -d /tmp/med-release-soak.XXXXXXXX)
out="$run/candidates"
qc="$run/qualification"
mkdir "$qc"
printf 'Evidence %s\n' "$run"
printf 'Detailed logs (in another Bash terminal):\n'
printf '  Candidate prep: tail -F %q/source-qc/{medex-core,medex-prepare}.log %q/sync.log\n' "$out" "$out"
printf '  Candidate build (once started): tail -F %q/build.*/build.log\n' "$out"
printf '  Native soak: tail -F %q/{soak-off,soak-isolated}/run.log\n' "$qc"
printf '  Five-second measurements: tail -F %q/{soak-off,soak-isolated}/soak-samples.jsonl\n' "$qc"

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
