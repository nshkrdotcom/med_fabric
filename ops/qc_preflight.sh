#!/usr/bin/env bash
# Cheap readiness check only. Never starts services, builds candidates or fills disks.
set -euo pipefail
umask 077
suite=${1:?Expected suite}
preview=${2:-isolated}
artifacts=${3:-}
volume=${4:-}
root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$root"
failures=0
required=(elixir mix python3 node npm cc make pkg-config jq curl openssl flock setsid timeout findmnt pg_config)
[[ "$suite" != all ]] || required+=(docker)
[[ "$preview" == off ]] || required+=(turnserver)
for tool in "${required[@]}"; do
  if ! command -v "$tool" >/dev/null; then
    printf 'UNAVAILABLE %s\n' "$tool" >&2
    failures=$((failures + 1))
  fi
done
((failures == 0)) || exit 2
export PATH="$(pg_config --bindir):$PATH"
for tool in initdb pg_ctl postgres psql createdb; do
  command -v "$tool" >/dev/null || { printf 'UNAVAILABLE PostgreSQL %s\n' "$tool" >&2; exit 2; }
done
initdb --version | grep -Eq '^initdb \(PostgreSQL\) 18\.' || {
  echo 'Preflight requires the existing PostgreSQL 18 contract.' >&2; exit 2;
}
source build_support/receipt_fixture.sh
medex_receipt_fixture "$root/../med_ex/core/med_core/test/fixtures/receipt_vectors_v2.json"
elixir --version
python3 --version
node --version
cc --version
opus=${MED_EX_OPUS_TARBALL:-}
[[ "$opus" == /* && -f "$opus" && ! -L "$opus" ]] || {
  echo 'Set MED_EX_OPUS_TARBALL to the absolute verified opus-1.5.2 archive before long qualification.' >&2; exit 2;
}
[[ "$(sha256sum "$opus" | cut -d' ' -f1)" == 65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1 ]] || {
  echo 'Pinned Opus archive checksum differs.' >&2; exit 2;
}
if [[ -n "$volume" ]]; then
  [[ -d "$volume" && -O "$volume" && -w "$volume" && ! -L "$volume" ]] || {
    echo 'Use an owned writable existing volume directory.' >&2; exit 2;
  }
  [[ "$(findmnt -T "$volume" -no FSTYPE)" == ext4 ]] || {
    echo 'Qualification volume must be actual ext4.' >&2; exit 2;
  }
  df -Pk -- "$volume"
fi
[[ "$suite" != soak || -n "$volume" ]] || { echo 'Soak preflight requires --volume.' >&2; exit 2; }
if [[ "$suite" == all ]]; then
  docker image inspect hapiproject/hapi@sha256:4771a178e764896c83881c1b3a52bd487e53d06e1acc3653ea0db0c6f6b2b8a1 >/dev/null || {
    echo 'The pinned HAPI image and Docker engine must be ready before qualification.' >&2; exit 2;
  }
fi
if [[ "$suite" != soak || "$preview" != off ]]; then
  (
    cd ops
    node -e 'const {chromium}=require("playwright");(async()=>{const b=await chromium.launch();await b.close()})().catch(()=>{console.error("Chromium/Playwright is not ready; install from ops/package-lock.json");process.exit(2)})'
  )
fi
[[ -n "$artifacts" ]] || { echo 'Supply the exact six-archive manifest for release preflight.' >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/fabric-preflight.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
elixir ops/detached_artifacts.exs inputs build_support/release_matrix.json "$artifacts" "$work/inputs.json"
registry=$(mix hex.repo show hexpm --url)
elixir ops/detached_artifacts.exs registry "$work/inputs.json" "$registry" "$work/registry.json"
printf 'Preflight PASS: tools, fixtures, exact archives and registry origin; no services started.\n'
