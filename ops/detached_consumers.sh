#!/usr/bin/env bash
# Qualification fixture only: install the supplied archives through a verified
# Hex registry and prepare role consumers outside both source repositories.
verify_detached_inputs() {
    local fabric=$1 manifest=$2 destination=$3 registry
    if [[ -e /etc/med_fabric/exam.json || -L /etc/med_fabric/exam.json ]]; then
        echo 'Run qualification in an isolated environment without a production Exam configuration.' >&2
        return 2
    fi
    elixir "$fabric/ops/detached_artifacts.exs" inputs "$fabric/build_support/release_matrix.json" \
        "$manifest" "$destination/artifacts.json"
    # Force signature, origin and TLS verification for every dependency resolve.
    # Registry selection is explicit Hex configuration, never a mirror bypass.
    export HEX_UNSAFE_HTTPS=false HEX_UNSAFE_REGISTRY=false HEX_NO_VERIFY_REPO_ORIGIN=false
    unset HEX_MIRROR HEX_MIRROR_URL HEX_TRUSTED_MIRROR HEX_TRUSTED_MIRROR_URL
    registry=$(cd "$destination" && MIX_ENV=prod mix hex.repo show hexpm --url)
    elixir "$fabric/ops/detached_artifacts.exs" registry "$destination/artifacts.json" \
        "$registry" "$destination/registry.json"
}

# Use the already installed workspace Blitz coordinator, not shell background
# jobs. The caller's candidate registry and native environment remain inherited.
run_detached_roles() (
    local fabric=$1 phase=$2 consumers=$3 releases=$4
    cd "$fabric"
    MIX_ENV=dev mix run --no-start --no-compile \
        -e 'MedFabric.Build.Workspace.run_detached_roles(System.argv())' -- \
        "$phase" "$consumers" "$releases"
)

prepare_detached_consumers() {
    local fabric=$1 manifest=$2 destination=$3 evidence=$4 app consumer package version started
    local -a packages
    mkdir -m 0700 -- "$destination"
    verify_detached_inputs "$fabric" "$manifest" "$destination"
    cp -- "$destination/artifacts.json" "$destination/registry.json" "$evidence/"

    for app in exam handheld preview; do
        started=$SECONDS
        printf 'Preparing detached %s consumer\n' "$app"
        consumer="$destination/$app"
        mkdir -m 0700 -- "$consumer" "$consumer/config"
        case "$app" in
            exam) packages=(med_ex mf_exam) ;;
            handheld) packages=(med_ex mf_handheld) ;;
            preview) packages=(med_ex med_ex_opus med_ex_rtc mf_preview) ;;
        esac
        {
            cat <<'MIX'
defmodule FabricDetached.MixProject do
  use Mix.Project
  def project do
    [app: :fabric_detached, version: "0.0.0", elixir: "~> 1.20",
MIX
            printf '     releases: [mf_%s: [applications: [mf_%s: :permanent], steps: [:assemble, &copy_runtime_inputs/1]]],\n' "$app" "$app"
            printf '     deps: [\n'
            for package in "${packages[@]}"; do
                version=$(jq -er --arg package "$package" '.packages[$package].version' "$destination/artifacts.json")
                printf '       {:%s, "%s"},\n' "$package" "$version"
            done
            cat <<'MIX'
     ]]
  end
  defp copy_runtime_inputs(release) do
    source = Path.join(__DIR__, "config/config_sources")
    if File.dir?(source) do
      File.cp_r!(source, Path.join([release.path, "releases", release.version, "config_sources"]))
    end
    release
  end
end
MIX
        } > "$consumer/mix.exs"
        cat > "$consumer/config/config.exs" <<'CONFIG'
import Config
config :logger, level: :info
CONFIG

        (
            cd "$consumer"
            MIX_ENV=prod mix deps.get
            MIX_ENV=prod mix deps.get --check-locked
            MIX_ENV=prod mix deps.tree > "$evidence/$app-dependencies.txt"
            elixir "$fabric/ops/detached_artifacts.exs" installed "$destination/artifacts.json" \
                "$consumer" "$app" "$evidence/$app-installed.json"
            cp -- mix.lock "$evidence/$app-mix.lock"

            if [[ $app != handheld ]]; then
                test -f "deps/mf_$app/config/config.exs" || {
                    printf 'Missing installed %s compile configuration.\n' "$app" >&2; exit 1;
                }
                test -f "deps/mf_$app/config/runtime.exs" || {
                    printf 'Missing installed %s runtime configuration.\n' "$app" >&2; exit 1;
                }
                printf 'import Config\nimport_config "../deps/mf_%s/config/config.exs"\nconfig :logger, level: :info\n' "$app" > config/config.exs
                # Weld's runtime entry evaluates files relative to __DIR__.
                # Preserve its entire installed config tree for both mix run
                # and the assembled release's runtime.exs location.
                cp -R -- "deps/mf_$app/config" config/config_sources
                printf 'import Config\nCode.eval_file(Path.expand("config_sources/runtime.exs", __DIR__))\n' > config/runtime.exs
            fi
        )
        printf 'Resolved and verified detached %s consumer (%ss)\n' "$app" "$((SECONDS-started))"
    done
    run_detached_roles "$fabric" compile "$destination" "$destination"
}

# Reuse only the role consumers from an explicitly supplied native run. Recheck
# the archive manifest, registry origin, lock bytes and installed package files
# against the original evidence before assembling releases. Never resolve a new
# lock or use a source checkout as a fallback.
reverify_detached_consumers() {
    local fabric=$1 manifest=$2 destination=$3 previous=$4 evidence=$5 app record
    [[ -d "$destination" && -O "$destination" && ! -L "$destination" &&
       -d "$previous" && -O "$previous" && ! -L "$previous" ]] || {
        echo 'Expected owned detached consumers and their original installation evidence.' >&2
        return 2
    }
    verify_detached_inputs "$fabric" "$manifest" "$evidence"
    for record in artifacts registry; do
        jq -e --slurpfile prior "$previous/$record.json" \
            '($prior | length) == 1 and . == $prior[0]' "$evidence/$record.json" >/dev/null
        jq -e --slurpfile prior "$destination/$record.json" \
            '($prior | length) == 1 and . == $prior[0]' "$evidence/$record.json" >/dev/null
    done
    for app in exam handheld preview; do
        [[ -d "$destination/$app" && -O "$destination/$app" && ! -L "$destination/$app" ]]
        cmp -- "$destination/$app/mix.lock" "$previous/$app-mix.lock"
        elixir "$fabric/ops/detached_artifacts.exs" installed "$evidence/artifacts.json" \
            "$destination/$app" "$app" "$evidence/$app-installed.json"
        jq -e --slurpfile prior "$previous/$app-installed.json" \
            '($prior | length) == 1 and . == $prior[0]' "$evidence/$app-installed.json" >/dev/null
        cp -- "$destination/$app/mix.lock" "$evidence/$app-mix.lock"
        # Same verified lock; retain the actual dependency tree from the original resolve.
        cp -- "$previous/$app-dependencies.txt" "$evidence/$app-dependencies.txt"
        printf 'Reverified detached %s consumer\n' "$app"
    done
}
