#!/usr/bin/env elixir
# Lightweight hardening & boundary guard for Med Fabric (no external services required).

root = Path.expand("..", __DIR__)

# 1. Verify erl_crash.dump is ignored by repo .gitignore
gitignore = File.read!(Path.join(root, ".gitignore"))

unless String.contains?(gitignore, "erl_crash.dump") do
  raise ".gitignore must explicitly ignore erl_crash.dump"
end

# 2. Verify all revision-2 operational guides exist
for guide <- ~w(
      guides/failure_matrix.md
      guides/operations_and_telemetry.md
      guides/security_and_clinical_boundary.md
      guides/clinical_core.md
    ) do
  path = Path.join(root, guide)
  unless File.regular?(path), do: raise("Missing hardening guide: #{guide}")
end

# 3. The host has no removed recorder or in-process native media dependency.
for file <- Path.wildcard(Path.join(root, "apps/exam/lib/**/*.ex")) do
  content = File.read!(file)

  for forbidden <- [
        "MedEx.Capture",
        "MedEx.Evidence",
        "MedEx.Preview",
        "MedEx.Web",
        "MedEx.Wav",
        "MedEx.RTC.Provider",
        "MedEx.Opus.Provider",
        "Membrane.",
        "ExWebRTC.",
        "MedEx.Storage.Journal",
        "MedEx.Storage.Records",
        "MedEx.Storage.Objects"
      ] do
    if String.contains?(content, forbidden) do
      raise "Forbidden private/removed reference #{forbidden} in #{file}"
    end
  end
end

# 4. Verify apps/exam/mix.exs no longer carries the Membrane :ratio git override
exam_mix = File.read!(Path.join(root, "apps/exam/mix.exs"))

if String.contains?(exam_mix, "elixir-rational.git") do
  raise "apps/exam/mix.exs still contains the removed Membrane :ratio git override"
end

# 5. Verify every code, suite, and guide path cited in the failure matrix exists
matrix = File.read!(Path.join(root, "guides/failure_matrix.md"))

for [path] <-
      Regex.scan(~r/`((?:apps|core|ops|guides)\/[^`\s,]+)`/, matrix, capture: :all_but_first) do
  unless File.exists?(Path.join(root, path)),
    do: raise("failure_matrix cites missing path: #{path}")
end

# 6. Verify projected mf_exam docs in build_support/weld.exs do not link to excluded .md files
{weld, _} = Code.eval_file(Path.join(root, "build_support/weld.exs"))
mf_exam = weld[:artifacts][:mf_exam]
projected_docs = [mf_exam[:flat][:readme] | mf_exam[:files][:docs]]
projected_names = MapSet.new(projected_docs, &Path.basename/1)

for doc <- projected_docs, String.ends_with?(doc, ".md") do
  content = File.read!(Path.join(root, doc))

  for [target] <-
        Regex.scan(~r/\]\(([^)#:\s]+\.md)(?:#[^)\s]*)?\)/, content, capture: :all_but_first) do
    unless MapSet.member?(projected_names, Path.basename(target)) do
      raise "Projected mf_exam doc #{doc} links to #{target}, which is not in build_support/weld.exs"
    end
  end
end

IO.puts("check_hardening ok")
