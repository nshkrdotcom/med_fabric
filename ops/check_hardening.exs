#!/usr/bin/env elixir
# Lightweight hardening & boundary guard for Med Fabric (no external services required).

root = Path.expand("..", __DIR__)

# 1. Verify erl_crash.dump is ignored by repo .gitignore
gitignore = File.read!(Path.join(root, ".gitignore"))

unless String.contains?(gitignore, "erl_crash.dump") do
  raise ".gitignore must explicitly ignore erl_crash.dump"
end

# 2. Verify all 0.3 hardening guides exist
for guide <- ~w(
      guides/failure_matrix.md
      guides/operations_and_telemetry.md
      guides/security_and_clinical_boundary.md
      guides/core_api_and_compatibility.md
    ) do
  path = Path.join(root, guide)
  unless File.regular?(path), do: raise("Missing hardening guide: #{guide}")
end

# 3. Verify apps/exam has no private reach-ins to MedEx.PreviewSession or Membrane
for file <- Path.wildcard(Path.join(root, "apps/exam/lib/**/*.ex")) do
  content = File.read!(file)

  for forbidden <- ["MedEx.PreviewSession", "Membrane."] do
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

IO.puts("check_hardening ok")
