#!/usr/bin/env bash
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${MF_CORE_DATABASE_URL_A:?Dedicated database A required}"
: "${MF_CORE_DATABASE_URL_B:?Dedicated database B required}"
: "${MF_CORE_DEPLOYMENT_UUID_A:?Stable independent deployment UUID A required}"
: "${MF_CORE_DEPLOYMENT_UUID_B:?Stable independent deployment UUID B required}"
: "${MF_CORE_FHIR_URL:?Explicit test FHIR destination required}"
: "${MF_CORE_PATIENT_REF:?Existing synthetic Patient reference required}"
: "${MF_CORE_ENCOUNTER_REF:?Existing synthetic Encounter reference required}"
[[ $MF_CORE_DATABASE_URL_A != "$MF_CORE_DATABASE_URL_B" ]]
[[ $MF_CORE_DEPLOYMENT_UUID_A != "$MF_CORE_DEPLOYMENT_UUID_B" ]]
work=$(mktemp -d "${TMPDIR:-/tmp}/mf-core-consumer.XXXXXXXX")
trap 'status=$?; printf "Core host evidence: %s (exit %s)\n" "$work" "$status"; exit "$status"' EXIT
mkdir -p "$work/core" "$work/examples"
for component in domain store interop; do
  mkdir -p "$work/core/$component"
  tar -C "core/$component" --exclude=_build --exclude=deps --exclude=.elixir_ls \
    --exclude='*.tar' -cf - . | tar -C "$work/core/$component" -xf -
done
cp -a examples/clinical_core "$work/examples/"
cd "$work/examples/clinical_core"
# Dependency selection is the bounded published requirement from each copied
# core project. An operator-configured authenticated candidate registry may be
# used before release. No Exam source, socket or process is present.
mix deps.get
mix deps.tree > "$work/dependency-tree.txt"
mix compile --warnings-as-errors
mix test --warnings-as-errors | tee "$work/test.log"
