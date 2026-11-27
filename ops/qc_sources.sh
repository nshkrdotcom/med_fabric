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
unset MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS
export MIX_ENV=test
cp "$repo_dir/config/sources.exs" "$qc_dir/sources.exs"
cat > "$qc_dir/mix.exs" <<'MIX'
Code.require_file("../sources.exs", __DIR__)

defmodule SourceConsumer.MixProject do
  use Mix.Project
  alias MedFabric.BuildSources

  def project do
    profile = System.fetch_env!("MED_EX_PROFILE")

    apps = case profile do
      "base" -> [:med_ex]
      "opus" -> [:med_ex_opus]
      "rtc" -> [:med_ex_rtc]
      "both" -> [:med_ex, :med_ex_opus, :med_ex_rtc]
    end

    choices = ".mix_sources.json" |> Path.expand(__DIR__) |> File.read!() |> JSON.decode!()

    defaults = Enum.map(apps, fn app ->
      unless is_map(choices) and Map.has_key?(choices, to_string(app)),
        do: Mix.raise("Supply a source for #{app} in the #{profile} profile")

      {^app, requirement, options} = BuildSources.med_ex_dependency(app)
      {app, requirement, options}
    end)

    {deps, paths} = BuildSources.resolve(defaults, __DIR__, __DIR__)
    [app: :source_consumer, version: "0.0.0", elixir: "~> 1.20", deps: deps] ++ paths
  end
end
MIX
cat > "$qc_dir/prove.exs" <<'ELIXIR'
profile = System.fetch_env!("MED_EX_PROFILE")
deps = Map.keys(Mix.Project.deps_paths())
base? = profile in ["base", "both"]
opus? = profile in ["opus", "both"]
rtc? = profile in ["rtc", "both"]
for {app, wanted?} <- [med_ex: base?, med_ex_opus: opus?, med_ex_rtc: rtc?] do
  unless (app in deps) == wanted?, do: raise("Unexpected package #{app} in #{profile}")
end
if base? do
  unless MedEx.Contract.api_revision() == 2, do: raise("API revision 2 is required")
  for module <- [MedEx.Receipt, MedEx.StreamWriter, MedEx.Wire.Credit] do
    unless Application.get_application(module) == :med_ex,
      do: raise("Incorrect SDK module ownership")
  end
end
for {app, module, wanted?} <- [{:med_ex_opus, MedEx.Opus.Provider, opus?},
                              {:med_ex_rtc, MedEx.RTC.Provider, rtc?}], wanted? do
  unless Code.ensure_loaded?(module) and Application.get_application(module) == app,
    do: raise("Incorrect provider ownership")
end
for app <- [:weld, :med_ex_maintainer, :med_core, :med_capture], app in deps,
  do: raise("Maintainer/private application leaked into consumer")

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

IO.puts("Source consumer passed: revision 2 / #{profile}")
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
    mix deps.get
    mix deps.tree
    mix compile --warnings-as-errors
    mix run prove.exs
  )
done
