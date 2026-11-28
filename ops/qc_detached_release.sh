#!/usr/bin/env bash
set -euo pipefail
umask 077

[[ ( $# == 3 || $# == 5 ) && $2 == --artifacts ]] || {
    echo 'Usage: ops/qc_detached_release.sh REPORT.json --artifacts MANIFEST.json [--native-evidence DIR]' >&2
    echo 'Provide all six exact archives and both prepared Weld identities; no source fallback is allowed.' >&2
    exit 2
}
report=$(realpath -m -- "$1")
artifact_manifest=$(realpath -e -- "$3")
native_evidence=
if [[ $# == 5 ]]; then
    [[ $4 == --native-evidence && -n $5 && -d $5 && ! -L $5 ]] || exit 2
    native_evidence=$(realpath -e -- "$5")
fi
export PATH="$(pg_config --bindir):$PATH"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ ! -e .mix_sources.json && ! -L .mix_sources.json ]]
fabric=$(pwd -P)
inputs="$report.inputs"
mkdir -m 0700 -- "$inputs"
lab=$(mktemp -d "${TMPDIR:-/tmp}/med-fabric-release.XXXXXXXX")
exam_pid= relay_pid= preview_pid=
pg_owned=false

stop_child() {
    local pid=$1 attempt parent

    [[ -n $pid ]] || return 0

    parent=$(ps -p "$pid" -o ppid= 2>/dev/null) || return 0

    [[ ${parent//[[:space:]]/} == "$$" ]] || return 0

    kill -TERM "$pid" 2>/dev/null || true

    for ((attempt=0; attempt<20; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done

    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi

    for ((attempt=0; attempt<8; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done

    if kill -0 "$pid" 2>/dev/null; then return 1; fi

    wait "$pid" 2>/dev/null || true
}

cleanup() {
    local status=$?
    trap - EXIT

    for pid in "$relay_pid" "$exam_pid" "$preview_pid"; do
        stop_child "$pid" || status=1
    done

    if "$pg_owned"; then
        pg_ctl -D "$lab/pgdata" -m fast -w stop || status=1
    fi

    if ((status)) && [[ ${MF_QC_KEEP_FAILURE:-0} == 1 ]]; then
        printf 'Private synthetic release evidence: %s\n' "$lab" >&2
    else
        rm -rf -- "$lab"
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

unset MF_LAB
unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE
unset MIX_EXS MIX_TARGET
unset MF_PUBLIC_ORIGIN MF_RELAY_ONLY MF_TURN_URLS MF_TURN_SECRET
unset MF_PROXY_SECRET MF_PREVIEW_URL MF_PREVIEW_CREDENTIAL_FILE MF_PREVIEW_CONFIG
unset MF_DEVICE_BIND_IP DATABASE_URL FHIR_BASE_URL
unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER
unset PGPASSWORD PGPASSFILE PGSERVICE PGSERVICEFILE

source "$fabric/ops/detached_consumers.sh"
elixir ops/handheld_demo.exs prepare --run-dir "$lab"
phase_started=$SECONDS
if [[ -n "$native_evidence" ]]; then
    jq -e -f ops/verify_native_report.jq "$native_evidence/native.json" >/dev/null
    consumers="$native_evidence/consumers"
    reverify_detached_consumers "$fabric" "$artifact_manifest" "$consumers" \
        "$native_evidence/installed" "$inputs"
    jq -e --slurpfile artifacts "$inputs/artifacts.json" \
        --slurpfile registry "$inputs/registry.json" \
        --slurpfile exam "$inputs/exam-installed.json" \
        --slurpfile handheld "$inputs/handheld-installed.json" \
        --slurpfile preview "$inputs/preview-installed.json" \
        '.artifact_manifest_sha256 == $artifacts[0].manifest_sha256 and
         .registry == $artifacts[0].registry and .registry_origin == $registry[0] and
         (.installed_artifacts | sort_by(.role)) == [$exam[0], $handheld[0], $preview[0]]' \
        "$native_evidence/native.json" >/dev/null
else
    consumers="$lab/consumers"
    prepare_detached_consumers "$fabric" "$artifact_manifest" "$consumers" "$inputs"
fi
printf 'Detached role inputs ready (%ss)\n' "$((SECONDS-phase_started))"
phase_started=$SECONDS

# The combined consumer exercises all six installed packages and real media.
# It is a separate proof from the three role processes below.
mkdir -m 0700 -- "$lab/combined"
cp -- "$fabric/examples/hex_smoke/mix.exs" "$lab/combined/"
cp -R -- "$fabric/examples/hex_smoke/config" "$fabric/examples/hex_smoke/test" "$lab/combined/"
(
    cd "$lab/combined"
    MIX_ENV=test mix deps.get
    MIX_ENV=test mix deps.get --check-locked
    elixir "$fabric/ops/detached_artifacts.exs" installed "$consumers/artifacts.json" \
        "$lab/combined" combined "$inputs/combined-installed.json"
    cp -- mix.lock "$inputs/combined-mix.lock"
    MIX_ENV=test mix test --warnings-as-errors | tee "$inputs/combined-tests.log"
)
printf 'Combined installed consumer passed (%ss)\n' "$((SECONDS-phase_started))"
phase_started=$SECONDS

cfg="$lab/server.json"
pg_port=$(jq -er .postgres_port "$cfg")

initdb -D "$lab/pgdata" -U lab \
    --auth-local=trust --auth-host=scram-sha-256 \
    --pwfile="$lab/postgres.credential" --no-locale

pg_ctl -D "$lab/pgdata" -l "$lab/logs/postgres.log" \
    -o "-k $lab/pghost -h 127.0.0.1 -p $pg_port" -w start

pg_owned=true

echo 'Building detached releases from their verified installed archives'
run_detached_roles "$fabric" release "$consumers" "$lab"

printf 'Detached database and release assembly complete (%ss)\n' "$((SECONDS-phase_started))"
phase_started=$SECONDS

for app in exam handheld preview; do
    test -z "$(find "$lab/$app-release/lib" \
        -mindepth 1 -maxdepth 1 \
        \( -name 'med_core-*' -o -name 'med_capture-*' -o -name 'med_ex_maintainer-*' \
        -o -name 'mf_domain-*' -o -name 'mf_store-*' -o -name 'mf_interop-*' \
        -o -name 'med_fabric_workspace-*' -o -name 'weld-*' \
        -o -name 'mix_workspace_ops-*' -o -name 'blitz-*' \) \
        -print -quit)"
done

for app in exam handheld; do
    test -z "$(find "$lab/$app-release/lib" \
        -mindepth 1 -maxdepth 1 \
        \( -name 'med_ex_opus-*' -o -name 'med_ex_rtc-*' \
        -o -name 'membrane_*' -o -name 'ex_webrtc-*' \
        -o -name 'ex_rtp-*' -o -name 'ex_rtcp-*' -o -name 'ex_srtp-*' \) \
        -print -quit)"
done

for app in med_ex med_ex_opus med_ex_rtc; do
    test -n "$(find "$lab/preview-release/lib" \
        -mindepth 1 -maxdepth 1 \
        -name "$app-*" -print -quit)"
done

preview_port=$(jq -er .preview_port "$cfg")
node_suffix=$(openssl rand -hex 6)
preview_cookie=$(openssl rand -hex 24)

(
    cd "$lab"

    exec env -i PATH="$PATH" ERL_FLAGS="${ERL_FLAGS:-}" LC_ALL=C.UTF-8 \
        MF_PREVIEW_CONFIG="$lab/preview-role/preview.json" \
        MF_PREVIEW_CREDENTIAL_FILE="$lab/preview-role/credential" \
        MF_PREVIEW_PORT="$preview_port" \
        RELEASE_TMP="$lab/preview-role/runtime" \
        RELEASE_NODE="mf_preview_qc_$node_suffix" \
        RELEASE_COOKIE="$preview_cookie" \
        bwrap --die-with-parent --unshare-user --unshare-pid \
        --ro-bind / / --dev-bind /dev /dev --proc /proc \
        --tmpfs "$lab" --dir "$lab/preview-role" \
        --ro-bind "$lab/preview-release" "$lab/preview-role/release" \
        --ro-bind "$lab/preview.credential" "$lab/preview-role/credential" \
        --ro-bind "$lab/preview.json" "$lab/preview-role/preview.json" \
        --dir "$lab/preview-role/runtime" \
        --tmpfs "$lab/preview-role/runtime" \
        --chdir "$lab/preview-role" -- /bin/sh -ec '
            test ! -r "$1/server.json"
            test ! -d "$1/artifact"
            test -z "${DATABASE_URL+x}"
            exec "$1/preview-role/release/bin/mf_preview" start
        ' sh "$lab"
) >"$lab/logs/preview-release.log" 2>&1 &

preview_pid=$!

await_denial() {
    local pid=$1 url=$2 log=$3 attempt code

    for ((attempt=0; attempt<60; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break

        code=$(curl --noproxy '*' --max-time 2 \
            -sS -o /dev/null -w '%{http_code}' \
            "$url" 2>/dev/null || true)

        if [[ $code == 403 ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi

        sleep 1
    done

    tail -n 30 "$log"
    return 1
}

await_denial "$preview_pid" \
    "http://127.0.0.1:$preview_port/status" \
    "$lab/logs/preview-release.log"

echo 'Preview release ready and isolated'

export MF_LAB=1
export MF_DEPLOYMENT_UUID="$(jq -er .deployment_uuid "$cfg")"
export MF_QC_SERVER_JSON="$cfg"
export MF_ENCOUNTERS_FILE="$lab/encounters.json"

jq -e .encounters "$cfg" > "$MF_ENCOUNTERS_FILE"

export DATABASE_URL="$(jq -er .database_url "$cfg")"
export MF_ARTIFACT_DIR="$(jq -er .artifact_dir "$cfg")"
export MF_SECRET_KEY_BASE="$(jq -er .cookie_secret "$cfg")"
export MF_HTTP_PORT="$(jq -er .http_port "$cfg")"
export MF_DEVICE_TLS_PORT="$(jq -er .tls_port "$cfg")"
export MF_DEVICE_TLS_CERTFILE="$(jq -er .cert "$cfg")"
export MF_DEVICE_TLS_KEYFILE="$(jq -er .key "$cfg")"
export MF_PREVIEW_URL="http://127.0.0.1:$preview_port"
export MF_PREVIEW_CREDENTIAL_FILE="$lab/preview.credential"
export RELEASE_NODE="mf_exam_qc_$node_suffix"
export RELEASE_DISTRIBUTION=sname
export RELEASE_COOKIE="$(openssl rand -hex 24)"

exam=$(jq -er '.encounters[0].exam' "$cfg")

(
    cd "$lab"
    exec ./exam-release/bin/mf_exam start
) >"$lab/logs/exam-release.log" 2>&1 &

exam_pid=$!

await_denial "$exam_pid" \
    "http://127.0.0.1:$MF_HTTP_PORT/encounters/$exam" \
    "$lab/logs/exam-release.log"

(
    cd "$lab"

    timeout 30 ./exam-release/bin/mf_exam rpc '
        alias MedFabric.Store.DeviceSessions
        db = MedFabric.Exam.context().db

        cfg =
          System.fetch_env!("MF_QC_SERVER_JSON")
          |> File.read!()
          |> JSON.decode!()

        encounters = Map.new(cfg["encounters"], &{&1["exam"], &1})

        for device <- cfg["devices"] do
          token =
            device["credential_file"]
            |> File.read!()
            |> String.trim()

          true = DeviceSessions.enroll(db, device["id"], token)

          if cfg["authorize_scenarios"] do
            encounter = Map.fetch!(encounters, device["exam"])

            for profile <- ~w(paired_exam plx_spot_check) do
              {:ok, :ok} = DeviceSessions.authorize(
                db,
                encounter["exam"], device["id"], profile,
                "Synthetic anterior site", encounter["clinician_actor"]
              )
            end
          end
        end

        IO.puts("Release device enrolled and authorized")
    '
)

(
    cd "$lab"
    exec elixir "$fabric/ops/handheld_demo.exs" relay --run-dir "$lab"
) >"$lab/logs/relay.log" 2>&1 &

relay_pid=$!
proxy_port=$(jq -er .proxy_port "$cfg")
relay_ready=false

for ((attempt=0; attempt<20; attempt++)); do
    kill -0 "$relay_pid" 2>/dev/null || break

    if timeout 2 bash -c \
        'exec 3<>"/dev/tcp/127.0.0.1/$1"' \
        _ "$proxy_port" 2>/dev/null; then

        relay_ready=true
        break
    fi

    sleep 0.25
done

"$relay_ready"

jq '.preview = true' "$lab/handheld-a.json" \
    > "$lab/handheld-release.json"

acquisition=$(jq -er .acquisition "$lab/handheld-release.json")

test ! -e "$lab/spool/$acquisition"

mkdir -m 0700 "$lab/handheld-home"

echo 'Starting detached Handheld acquisition'

(
    cd "$lab"

    env -i PATH="$PATH" ERL_FLAGS="${ERL_FLAGS:-}" LC_ALL=C.UTF-8 MIX_HOME="$lab/handheld-home/mix" HEX_HOME="$lab/handheld-home/hex" \
        timeout 180 ./handheld-release/bin/mf_handheld eval '
            {:ok, _} = Application.ensure_all_started(:mf_handheld)

            MedFabric.Handheld.CLI.main([
              "--config", "handheld-release.json",
              "--scenario", "paired_exam"
            ])
        '
)

artifact_name=$(printf '%s' "$acquisition" | openssl dgst -sha256 -r)
artifact="$MF_ARTIFACT_DIR/acquisitions-v2/${artifact_name%% *}"
manifest="$artifact/manifest.mej1"

manifest_digest=$(openssl dgst -sha256 -r "$manifest")
manifest_digest=${manifest_digest%% *}

client_digest=$(jq -er .manifest_digest \
    "$lab/spool/$acquisition/result.json")

database_digest=$(psql "$DATABASE_URL" -XAt \
    -v ON_ERROR_STOP=1 -v acquisition="$acquisition" <<'SQL'
SELECT digest FROM acquisition_manifests WHERE acquisition_id = :'acquisition';
SQL
)

test "$manifest_digest" = "$client_digest"
test "$manifest_digest" = "$database_digest"

for stream in audio ecg; do
    fence=$(jq -er --arg stream "$stream" \
        '.streams[$stream].index.fence' "$manifest")

    jq -e --arg stream "$stream" \
        '.streams[$stream].index.segments | length > 0' \
        "$manifest" >/dev/null

    while IFS=$'\t' read -r key expected; do
        actual=$(openssl dgst -sha256 -r \
            "$artifact/$stream/$fence/$key")

        test "${actual%% *}" = "$expected"
    done < <(
        jq -er --arg stream "$stream" \
            '.streams[$stream].index.segments[] |
             [.key,.sha256] | @tsv' "$manifest"
    )
done

printf 'PASS detached production acquisition: %s\n' "$acquisition"
printf 'Verified manifest digest: %s\n' "$manifest_digest"
printf 'Detached production acquisition and verification passed (%ss)\n' "$((SECONDS-phase_started))"

jq -n --arg sha "$manifest_digest" --slurpfile artifacts "$consumers/artifacts.json" \
    --slurpfile registry "$consumers/registry.json" \
    --slurpfile exam "$inputs/exam-installed.json" --slurpfile handheld "$inputs/handheld-installed.json" \
    --slurpfile preview "$inputs/preview-installed.json" --slurpfile combined "$inputs/combined-installed.json" \
    --argjson audio "$(jq '.streams.audio.index.segments | length' "$manifest")" \
    --argjson ecg "$(jq '.streams.ecg.index.segments | length' "$manifest")" \
    '{schema:"medfabric.detached_release.v2",manifest_sha256:$sha,verified_segments:{audio:$audio,ecg:$ecg},
      preview_isolated:true,artifact_manifest_sha256:$artifacts[0].manifest_sha256,
      registry:$artifacts[0].registry,registry_origin:{kind:$registry[0].kind,url:$registry[0].url},
      installed:[$exam[0],$handheld[0],$preview[0]],
      combined:$combined[0]}' > "$report"
