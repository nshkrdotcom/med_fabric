#!/usr/bin/env bash
# Qualification fixture only: install the supplied archives through a verified
# Hex registry and prepare role consumers outside both source repositories.
prepare_detached_consumers() {
    local fabric=$1 manifest=$2 destination=$3 evidence=$4 app consumer package version registry
    local -a packages
    if [[ -e /etc/med_fabric/exam.json || -L /etc/med_fabric/exam.json ]]; then
        echo 'Run qualification in an isolated environment without a production Exam configuration.' >&2
        return 2
    fi
    mkdir -m 0700 -- "$destination"
    elixir "$fabric/ops/detached_artifacts.exs" inputs "$fabric/build_support/release_matrix.json" \
        "$manifest" "$destination/artifacts.json"
    cp -- "$destination/artifacts.json" "$evidence/artifacts.json"
    # Force signature, origin and TLS verification for every dependency resolve.
    # Registry selection is explicit Hex configuration, never a mirror bypass.
    export HEX_UNSAFE_HTTPS=false HEX_UNSAFE_REGISTRY=false HEX_NO_VERIFY_REPO_ORIGIN=false
    unset HEX_MIRROR HEX_MIRROR_URL HEX_TRUSTED_MIRROR HEX_TRUSTED_MIRROR_URL
    registry=$(cd "$destination" && MIX_ENV=prod mix hex.repo show hexpm --url)
    elixir "$fabric/ops/detached_artifacts.exs" registry "$destination/artifacts.json" \
        "$registry" "$evidence/registry.json"
    cp -- "$evidence/registry.json" "$destination/registry.json"

    for app in exam handheld preview; do
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
        printf 'import Config\n' > "$consumer/config/config.exs"

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
                printf 'import Config\nimport_config "../deps/mf_%s/config/config.exs"\n' "$app" > config/config.exs
                # Weld's runtime entry evaluates files relative to __DIR__.
                # Preserve its entire installed config tree for both mix run
                # and the assembled release's runtime.exs location.
                cp -R -- "deps/mf_$app/config" config/config_sources
                printf 'import Config\nCode.eval_file(Path.expand("config_sources/runtime.exs", __DIR__))\n' > config/runtime.exs
            fi
            MIX_ENV=prod mix compile --warnings-as-errors
        )
    done
}
