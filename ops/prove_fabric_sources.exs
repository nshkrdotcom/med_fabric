# Executed by the actual app's ordinary Mix project after dependency resolution.
profile = System.fetch_env!("MF_SOURCE_QC_PROFILE")
native? = profile in ["preview", "legacy-exam"]
paths = Mix.Project.deps_paths()

for app <- [:med_ex, :med_ex_opus, :med_ex_rtc] do
  wanted? = app == :med_ex or native?
  unless Map.has_key?(paths, app) == wanted?, do: raise("Unexpected #{app} in #{profile}")

  if wanted? do
    _ = Application.load(app)
    version = Application.spec(app, :vsn) |> to_string()

    unless Version.match?(version, "~> 0.2.0"),
      do: raise("Incompatible actual #{app} version #{version}")
  end
end

unless MedEx.Contract.api_revision() == 1, do: raise("Wrong MedEx contract")

for asset <- ~w(pcm_capture.js pcm_worklet.js session_hook.js) do
  unless File.regular?(MedEx.Web.asset_path(asset)), do: raise("Missing SDK asset #{asset}")
end

for module <- [MedEx.StreamSpec, MedEx.SampleFrame, MedEx.StreamWriter, MedEx.ClockAlign] do
  unless Code.ensure_loaded?(module) and Application.get_application(module) == :med_ex,
    do: raise("Wrong base ownership for #{inspect(module)}")
end

for {app, module} <- [{:med_ex_opus, MedEx.Opus.Provider}, {:med_ex_rtc, MedEx.RTC.Provider}] do
  if native? do
    unless Code.ensure_loaded?(module) and Application.get_application(module) == app,
      do: raise("Wrong provider ownership for #{app}")
  else
    if Code.ensure_loaded?(module), do: raise("Provider leaked into #{profile}")
  end
end

for app <- Map.keys(paths) do
  name = Atom.to_string(app)

  if app in [:weld, :mix_workspace_ops, :med_ex_maintainer, :med_core, :med_capture, :med_rtc],
    do: raise("Tooling/component leaked into #{profile}: #{app}")

  if not native? and
       (String.starts_with?(name, "membrane_") or app in [:ex_webrtc, :ex_rtp, :ex_rtcp, :ex_srtp]),
     do: raise("Native media dependency leaked into #{profile}: #{app}")
end

if native? do
  for app <- [:membrane_opus_plugin, :ex_webrtc] do
    unless Map.has_key?(paths, app), do: raise("Native provider dependency missing: #{app}")
  end
end

config = Mix.Project.config()
mutable = Keyword.take(config, [:lockfile, :deps_path, :build_path])

if System.get_env("MF_SOURCE_QC_EXPECT_DEFAULT") == "1" and profile != "legacy-exam" do
  unless mutable == [], do: raise("Default app changed its ordinary Mix paths")
else
  unless length(mutable) == 3 and
           Enum.all?(mutable, fn {_, p} -> String.contains?(p, "/source_contexts/") end),
         do: raise("Actual app has shared mutable state")
end

lock = Mix.Dep.Lock.read()

if profile == "legacy-exam" do
  {:git, _, "05191dbe8061b49a170352f3c35c21360bdbb328", _} = Map.fetch!(lock, :ratio)
end

for {app, requirement, source} <- config[:deps], app in [:med_ex, :med_ex_opus, :med_ex_rtc] do
  cond do
    source[:path] ->
      unless Path.expand(Map.fetch!(paths, app)) == source[:path] and not Map.has_key?(lock, app),
        do: raise("Wrong path resolution for #{app}")

    source[:hex] ->
      {:hex, package, version, _, _, _, repo, _} = Map.fetch!(lock, app)

      unless to_string(package) == source[:hex] and repo == source[:repo] and
               Version.match?(version, requirement),
             do: raise("Wrong Hex resolution for #{app}")

    source[:git] || source[:github] ->
      {:git, _, revision, options} = Map.fetch!(lock, app)

      {actual, 0} = System.cmd("git", ["-C", Map.fetch!(paths, app), "rev-parse", "HEAD"])

      unless revision == source[:ref] and options[:subdir] == source[:subdir] and
               String.trim(actual) == revision,
             do: raise("Wrong Git resolution for #{app}")
  end
end

IO.inspect(mutable, label: "isolated mutable paths")
IO.puts("Actual Fabric project passed: #{profile}")
