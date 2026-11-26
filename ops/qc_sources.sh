#!/usr/bin/env bash
# Test a supplied MedEx family in a fresh ordinary Mix consumer per profile.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
profile=${MED_EX_PROFILE:-base}
case "$profile" in
  base|opus|rtc|both) profiles=("$profile") ;;
  all) profiles=(base opus rtc both) ;;
  *) echo 'MED_EX_PROFILE must be base, opus, rtc, both or all.' >&2; exit 2 ;;
esac
if [[ -z ${MED_EX_SOURCE:-} ]]; then
  echo 'Set MED_EX_SOURCE to a .mix_sources.json object with every selected app. Use absolute local paths.' >&2
  exit 2
fi
command -v mix >/dev/null || { echo 'Elixir 1.20 and Mix are required.' >&2; exit 127; }
qc_dir=$(mktemp -d)
trap 'rm -rf "$qc_dir"' EXIT
unset MF_MED_EX_PATH MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS
export MIX_ENV=test
export EXPECT_MED_EX_CONTRACT=${EXPECT_MED_EX_CONTRACT:-stream_v1}
if [[ $EXPECT_MED_EX_CONTRACT =~ ^(legacy|reject_legacy)$ && $profile != base ]]; then
  echo 'The historical SDK can only be checked in the base profile.' >&2
  exit 2
fi
cp "$repo_dir/config/sources.exs" "$qc_dir/sources.exs"
cat > "$qc_dir/mix.exs" <<'MIX'
Code.require_file("../sources.exs", __DIR__)

defmodule SourceConsumer.MixProject do
  use Mix.Project
  alias MedFabric.BuildSources

  def project do
    profile = System.fetch_env!("MED_EX_PROFILE")

    apps =
      [:med_ex] ++
        if(profile in ["opus", "both"], do: [:med_ex_opus], else: []) ++
        if(profile in ["rtc", "both"], do: [:med_ex_rtc], else: [])

    choices = ".mix_sources.json" |> Path.expand(__DIR__) |> File.read!() |> JSON.decode!()

    defaults = Enum.map(apps, fn app ->
      unless is_map(choices) and Map.has_key?(choices, to_string(app)),
        do: Mix.raise("Supply a source for #{app} in the #{profile} profile")

      {^app, requirement, options} = BuildSources.med_ex_dependency(app)
      requirement = if app == :med_ex, do: System.get_env("MED_EX_REQUIREMENT", requirement), else: requirement
      {app, requirement, options}
    end)

    {deps, paths} = BuildSources.resolve(defaults, __DIR__, __DIR__)
    [app: :source_consumer, version: "0.0.0", elixir: "~> 1.20", deps: deps] ++ paths
  end
end
MIX
cat > "$qc_dir/prove.exs" <<'ELIXIR'
contract = System.fetch_env!("EXPECT_MED_EX_CONTRACT")
profile = System.fetch_env!("MED_EX_PROFILE")
unless contract in ["legacy", "stream_v1"], do: raise("Unknown expected contract")
unless Code.ensure_loaded?(MedEx.Capture), do: raise("Missing browser capture facade")

assets = if contract == "legacy", do: ["pcm_worklet.js"], else: ~w(pcm_capture.js pcm_worklet.js session_hook.js)
for asset <- assets do
  unless File.regular?(MedEx.Web.asset_path(asset)), do: raise("Missing browser asset #{asset}")
end

revision =
  if Code.ensure_loaded?(MedEx.Contract) and function_exported?(MedEx.Contract, :api_revision, 0),
    do: apply(MedEx.Contract, :api_revision, []),
    else: nil

case {contract, revision} do
  {"legacy", nil} -> :ok
  {"stream_v1", 1} -> :ok
  {"stream_v1", _} -> raise "Selected SDK lacks the stream-v1 contract"
  {"legacy", _} -> raise "Expected the historical standalone SDK"
end

if contract == "stream_v1" do
  deps = Map.keys(Mix.Project.deps_paths())
  wanted_opus? = profile in ["opus", "both"]
  wanted_rtc? = profile in ["rtc", "both"]
  for {dep, wanted?} <- [med_ex_opus: wanted_opus?, elixir_make: wanted_opus?,
                        med_ex_rtc: wanted_rtc?, ex_webrtc: wanted_rtc?] do
    unless (dep in deps) == wanted?, do: raise("Unexpected package #{dep} in #{profile}")
  end

  if profile == "base" do
    for app <- deps, String.starts_with?(Atom.to_string(app), "membrane_") or app in [:ex_webrtc, :ex_rtp, :ex_rtcp, :ex_srtp],
      do: raise("Native media dependency leaked into base: #{app}")
  end

  forbidden = [:weld, :mix_workspace_ops, :med_ex_maintainer, :med_core, :med_capture, :med_rtc]
  for app <- forbidden, app in deps, do: raise("Unexpected dependency #{app}")
  for module <- [MedEx.StreamSpec, MedEx.SampleFrame, MedEx.StreamWriter, MedEx.ClockAlign] do
    unless Application.get_application(module) == :med_ex, do: raise("Incorrect base module ownership")
  end

  providers = [{:med_ex_opus, MedEx.Opus.Provider, wanted_opus?},
               {:med_ex_rtc, MedEx.RTC.Provider, wanted_rtc?}]
  for {app, module, true} <- providers do
    unless Code.ensure_loaded?(module) and Application.get_application(module) == app,
      do: raise("Incorrect provider application #{app}")
  end
end

paths = Keyword.take(Mix.Project.config(), [:lockfile, :build_path, :deps_path])
unless length(paths) == 3 and Enum.all?(paths, fn {_, path} -> String.contains?(path, "/source_contexts/") end),
  do: raise("Source context did not isolate all mutable paths")
unless File.read!("mix.lock") == "%{}\n", do: raise("Default lock was modified")

lock =
  if File.regular?(paths[:lockfile]) do
    {lock, []} = Code.eval_file(paths[:lockfile])
    lock
  else
    %{}
  end

resolved_paths = Mix.Project.deps_paths()
for {app, requirement, source} <- Mix.Project.config()[:deps] do
  cond do
    source[:path] ->
      unless Path.expand(Map.fetch!(resolved_paths, app)) == source[:path] and not Map.has_key?(lock, app),
        do: raise("Unexpected path resolution for #{app}")

    source[:hex] ->
      {:hex, package, version, _, _, _, repo, _} = Map.fetch!(lock, app)
      unless to_string(package) == source[:hex] and repo == source[:repo] and Version.match?(version, requirement),
        do: raise("Unexpected Hex resolution for #{app}")
      IO.puts("Resolved #{app} #{version} from #{repo}")

    source[:git] || source[:github] ->
      {:git, _origin, revision, options} = Map.fetch!(lock, app)
      unless options[:subdir] == source[:subdir], do: raise("Unexpected Git subdir for #{app}")
      if revision != source[:ref],
        do: raise("Unexpected Git revision for #{app}")
      IO.puts("Resolved #{app} at #{revision}")
  end
end

IO.puts("Source consumer passed: #{contract} / #{profile}")
IO.inspect(paths, label: "isolated paths")
ELIXIR

for selected in "${profiles[@]}"; do
  work="$qc_dir/$selected"
  mkdir "$work"
  cp "$qc_dir"/{mix.exs,prove.exs} "$work/"
  printf '%s\n' "$MED_EX_SOURCE" > "$work/.mix_sources.json"
  printf '%%{}\n' > "$work/mix.lock"
  (
    cd "$work"
    export MED_EX_PROFILE=$selected
    if [[ $EXPECT_MED_EX_CONTRACT == reject_legacy ]]; then
      # Prove the genuine historical package first, then attempt to consume
      # exactly those downloaded bytes under the current stream-v1 requirement.
      export MED_EX_REQUIREMENT='== 0.1.0' EXPECT_MED_EX_CONTRACT=legacy
      mix deps.get
      mix deps.tree
      mix compile --warnings-as-errors
      mix run prove.exs
      legacy_path=$(mix run --no-start -e 'IO.puts(Map.fetch!(Mix.Project.deps_paths(), :med_ex))' | tail -n1)
      test -f "$legacy_path/mix.exs"
      elixir -e 'IO.puts(JSON.encode!(%{"med_ex" => %{"path" => hd(System.argv())}}))' -- "$legacy_path" > .mix_sources.json
      unset MED_EX_REQUIREMENT
      export EXPECT_MED_EX_CONTRACT=stream_v1
      if (mix deps.get && mix compile --warnings-as-errors) > rejection.log 2>&1; then
        cat rejection.log >&2
        echo 'Historical SDK unexpectedly satisfied the stream-v1 consumer.' >&2
        exit 1
      fi
      cat rejection.log
      grep -Eiq 'does not satisfy med_ex|med_ex.*(0\.1\.0|version).*(does not match|does not satisfy|mismatch)|version.*mismatch.*med_ex|does not match the requirement' rejection.log
      echo 'Verified historical package rejected by the stream-v1 consumer.'
    else
      mix deps.get
      mix deps.tree
      mix compile --warnings-as-errors
      mix run prove.exs
    fi
  )
done
