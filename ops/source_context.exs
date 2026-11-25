# From a Fabric Mix project: elixir ../../ops/source_context.exs
# Inspect the paths Mix actually selected without fetching, compiling or printing URLs.
Mix.start()

Mix.Project.in_project(:fabric_source_context, ".", [], fn _ ->
  config = Mix.Project.config()

  IO.puts("Application: #{config[:app]}")
  IO.puts("Environment: #{Mix.env()} target: #{Mix.target()}")
  IO.puts("Lock: #{Path.expand(config[:lockfile] || "mix.lock")}")
  IO.puts("Dependencies: #{Mix.Project.deps_path(config)}")
  IO.puts("Build: #{Mix.Project.build_path(config)}")

  for {app, _requirement, opts} <- config[:deps], app in [:med_ex, :med_ex_opus, :med_ex_rtc] do
    kind =
      cond do
        opts[:path] -> "path"
        opts[:github] || opts[:git] -> "pinned Git"
        true -> "Hex"
      end

    IO.puts("#{app}: #{kind}")
  end

  IO.puts("Hex owns archive caching. Writable dependency and BEAM trees are context-private.")
end)
