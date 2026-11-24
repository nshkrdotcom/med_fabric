#!/usr/bin/env bash
# Exercise an existing SDK source with ordinary Mix, outside all source trees.
# This script never generates a projection or installs Weld/MWS.
# Example:
# MED_EX_SOURCE='{"med_ex":{"path":"/absolute/path/to/med_ex"}}' bash ops/qc_sources.sh
# Repeat with existing live/full/prepared paths, GitHub refs and Hex selections.
# Set MED_EX_REQUIREMENT="== 0.1.0" for the published legacy contract.
# EXPECT_MED_EX_CONTRACT=legacy checks the legacy API.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
qc_dir=$(mktemp -d)
trap 'rm -rf "$qc_dir"' EXIT
if [[ -z ${MED_EX_SOURCE:-} ]]; then
  echo 'Set MED_EX_SOURCE to a complete .mix_sources.json object; use absolute local paths.' >&2
  exit 2
fi
unset MF_MED_EX_PATH MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE
export MIX_ENV=test
export EXPECT_MED_EX_CONTRACT=${EXPECT_MED_EX_CONTRACT:-stream_v1}
export MED_EX_REQUIREMENT=${MED_EX_REQUIREMENT:-~> 0.2.0}
cp "$repo_dir/config/sources.exs" "$qc_dir/sources.exs"
printf '%s\n' "$MED_EX_SOURCE" > "$qc_dir/.mix_sources.json"
printf '%%{}\n' > "$qc_dir/mix.lock"
cat > "$qc_dir/mix.exs" <<'MIX'
Code.require_file("sources.exs", __DIR__)
defmodule SourceConsumer.MixProject do
  use Mix.Project
  def project do
    {deps, paths} = MedFabric.BuildSources.resolve(
      [{:med_ex, System.fetch_env!("MED_EX_REQUIREMENT"), override: true}], __DIR__, __DIR__)
    [app: :source_consumer, version: "0.0.0", elixir: "~> 1.20", deps: deps] ++ paths
  end
end
MIX
cat > "$qc_dir/prove.exs" <<'ELIXIR'
profile = System.fetch_env!("EXPECT_MED_EX_CONTRACT")
unless profile in ["legacy", "stream_v1"], do: raise("Unknown expected contract")
case Application.load(:med_ex) do
  :ok -> :ok
  {:error, {:already_loaded, :med_ex}} -> :ok
  other -> raise("Cannot load MedEx application metadata: #{inspect(other)}")
end
unless Code.ensure_loaded?(MedEx.Capture), do: raise("Missing legacy capture facade")
unless File.regular?(MedEx.Web.asset_path("pcm_worklet.js")), do: raise("Missing canonical browser asset")
if profile == "stream_v1" do
  unless Code.ensure_loaded?(MedEx.Contract) and
      function_exported?(MedEx.Contract, :api_revision, 0) and
      MedEx.Contract.api_revision() == 1,
    do: raise("Selected MedEx source lacks stream contract v1; pin a verified new source commit")
  for module <- [MedEx.StreamSpec, MedEx.SampleFrame, MedEx.StreamWriter, MedEx.ClockAlign] do
    unless Application.get_application(module) == :med_ex,
      do: raise("Incorrect OTP module ownership for #{inspect(module)}")
  end
  deps = Map.keys(Mix.Project.deps_paths())
  for app <- [:weld, :mix_workspace_ops, :med_core, :med_capture, :med_rtc,
      :membrane_core, :membrane_opus_plugin, :ex_webrtc] do
    if app in deps, do: raise("Headless consumer unexpectedly installs #{app}")
  end
end
config = Mix.Project.config()
paths = Keyword.take(config, [:lockfile, :build_path, :deps_path])
unless length(paths) == 3 and Enum.all?(paths, fn {_, p} -> String.contains?(p, "/source_contexts/") end),
  do: raise("Source context did not isolate all mutable paths")
unless File.read!("mix.lock") == "%{}\n", do: raise("Committed default lock was modified")
IO.puts("Source consumer passed: #{profile}")
IO.inspect(paths, label: "isolated paths")
ELIXIR
(
  cd "$qc_dir"
  mix deps.get
  mix compile --warnings-as-errors
  mix run --no-start prove.exs
)
