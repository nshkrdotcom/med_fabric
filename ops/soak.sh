#!/usr/bin/env bash
set -euo pipefail
umask 077
fab=$(cd "$(dirname "$0")/.." && pwd -P)
sdk=$(cd "$fab/../med_ex" && pwd -P)
tools_dir=/tmp/med-release-qc.6XQST7
export PATH="$tools_dir/native-tools/bin:$(pg_config --bindir):$PATH"
export MED_EX_OPUS_TARBALL="$(cat "$tools_dir/opus-archive-path")"
export MEDEX_RECEIPT_VECTORS="$sdk/core/med_core/test/fixtures/receipt_vectors_v2.json"
test -f "$MED_EX_OPUS_TARBALL"
test -z "$(git -C "$sdk" status --porcelain)"
test -z "$(git -C "$fab" status --porcelain)"
git -C "$sdk" merge-base --is-ancestor 90568d9 HEAD
git -C "$fab" merge-base --is-ancestor 6750fd5 HEAD

run=$(mktemp -d /tmp/med-release-soak.XXXXXXXX)
out="$run/candidates"
qc="$run/qualification"
mkdir "$qc"
volume_base=${SOAK_EXT4_BASE:-/var/tmp}
test "$(findmnt -T "$volume_base" -no FSTYPE)" = ext4
volume=$(mktemp -d "$volume_base/med-soak.XXXXXXXX")
printf '%s\n' "$volume" > "$qc/soak-volume-path"
printf 'Evidence %s\nLabs %s\n' "$run" "$volume"

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
      jq -e --arg preview "$mode" -f ops/verify_soak_report.jq "$qc/soak-$mode/native.json"
    done
  ' soak "$fab" "$manifest" "$qc" "$volume"
