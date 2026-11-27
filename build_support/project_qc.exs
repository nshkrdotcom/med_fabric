defmodule MedFabric.Build.ProjectQC do
  @moduledoc false
  alias Mix.Dep.Lock
  @compile {:no_warn_undefined, [Credo, Credo.Execution]}
  @script Path.join(__DIR__, "run_project_qc.exs")
  @coordinator :med_fabric_workspace
  @boundary_apps [:med_core, :med_capture, :med_ex_maintainer, :med_fabric_maintainer]

  def main([task | args]) do
    {options, forwarded} = Enum.split_with(args, &(&1 in ["--locked", "--release"]))

    if task in ["setup", "quality"] and forwarded != [],
      do: Mix.raise("Unexpected arguments for #{task}")

    dispatch(task, options, forwarded)
  end

  defp dispatch("setup", options, _args), do: setup(options)
  defp dispatch("quality", options, _args), do: quality(options)
  defp dispatch("test", _options, args), do: in_environment("test", "native_test", args)
  defp dispatch("native_test", _options, args), do: test(args)
  defp dispatch("tooling_test", _options, _args), do: tooling_test()
  defp dispatch("credo", _options, args), do: credo(args)
  defp dispatch("dialyzer", _options, args), do: dialyzer(args)
  defp dispatch("docs", _options, args), do: native("docs", ["--warnings-as-errors" | args])

  defp dispatch("format", _options, _args),
    do: native("format", ["--check-formatted" | sources()])

  defp dispatch("compile", _options, args), do: native("compile", ["--warnings-as-errors" | args])
  defp dispatch(task, _options, _args), do: Mix.raise("Unknown project QC phase #{task}")

  def native(task, args) do
    if task not in ["deps.get", "format"] do
      prepare_dependencies()

      if task == "compile" do
        Mix.Task.reenable("compile")
        Mix.Task.reenable("compile.all")
      end
    end

    module = Mix.Task.get(task) || Mix.raise("Missing native task #{task}; run mix setup")
    module.run(args)
  end

  defp setup(options) do
    for env <- ["dev", "test", "prod"] do
      args = if "--locked" in options, do: ["--check-locked"], else: []
      in_environment(env, "deps_get", args)
    end
  end

  def main_deps(args) do
    config = Mix.Project.config()
    lock = Path.expand(config[:lockfile] || "mix.lock")
    baseline = Path.expand("mix.lock")

    if lock != baseline, do: seed_source_lock(config[:deps], lock, baseline, args)

    native("deps.get", args)
  end

  defp seed_source_lock(deps, lock, baseline, args) do
    Mix.Project.with_deps_lock(fn ->
      current = Lock.read(lock)
      existing? = File.exists?(lock)
      seed = if existing?, do: current, else: Lock.read(baseline)

      # Hex validates old lock entries before resolving the new SCM, so a
      # candidate Hex entry can block a source override even for a local path.
      filtered = Enum.reduce(deps, seed, &drop_source_lock/2)

      if filtered != current do
        File.mkdir_p!(Path.dirname(lock))
        Lock.write(filtered, check_locked: existing? and "--check-locked" in args)
      end
    end)
  end

  defp drop_source_lock(dep, lock) do
    app = elem(dep, 0)
    options = elem(dep, tuple_size(dep) - 1)
    hex_lock? = match?({:hex, _, _, _, _, _, _, _}, lock[app])

    if is_list(options) and
         (options[:path] || (hex_lock? and (options[:git] || options[:github]))) do
      Map.delete(lock, app)
    else
      lock
    end
  end

  defp quality(options) do
    app = Mix.Project.config()[:app]

    phases = quality_phases(app)
    phases = if "--release" in options, do: phases ++ ["compile_prod"], else: phases

    {results, _} = Enum.map_reduce(phases, true, &run_phase(app, &1, &2))
    unless Enum.all?(results, &(&1 == 0)), do: Mix.raise("Project QC failed; see phase exits")
  end

  defp run_phase(app, phase, false) when phase in ["dialyzer", "docs"] do
    IO.puts("BLOCKED #{app} #{phase}: development compile failed")
    {1, false}
  end

  defp run_phase(app, phase, compiled?) do
    {env, task} = if phase == "compile_prod", do: {"prod", "compile"}, else: {"dev", phase}
    status = child(env, task, [])
    IO.puts("QC #{app} #{phase} exit=#{status}")
    {status, if(phase == "compile", do: status == 0, else: compiled?)}
  end

  defp quality_phases(app) when app in @boundary_apps, do: ~w(compile test)
  defp quality_phases(@coordinator), do: ~w(tooling_test format credo docs)
  defp quality_phases(:med_ex), do: ~w(tooling_test format compile test credo dialyzer docs)
  defp quality_phases(_app), do: ~w(format compile test credo dialyzer docs)

  defp test(args) do
    receipt_fixture!()
    unless Mix.env() == :test, do: Mix.raise("Tests require MIX_ENV=test")
    native("compile", ["--warnings-as-errors"])

    app = Mix.Project.config()[:app]
    tests = Mix.Project.config()[:test_paths] || ["test"]
    present? = Enum.any?(tests, &(Path.wildcard(Path.join(&1, "**/*_test.exs")) != []))

    cond do
      not present? and app in [:med_ex_maintainer, :med_fabric_maintainer] ->
        IO.puts("NOT APPLICABLE: this maintainer has no ExUnit suite")

      not present? ->
        Mix.raise("No ExUnit suite found for #{app}")

      true ->
        native("test", ["--no-compile", "--warnings-as-errors" | args])
    end
  end

  defp tooling_test do
    files =
      ~w(build_support/workspace_test.exs config/sources_test.exs config/runtime_test.exs ops/check_hardening.exs ops/check_hardening_test.exs ops/detached_artifacts_test.exs)

    statuses =
      Enum.map(files, fn file ->
        {_output, status} =
          System.cmd("elixir", [file], into: IO.stream(:stdio, :line), stderr_to_stdout: true)

        IO.puts("QC tooling #{file} exit=#{status}")
        status
      end)

    unless Enum.all?(statuses, &(&1 == 0)), do: Mix.raise("Tooling regressions failed")
  end

  defp receipt_fixture! do
    if Mix.Project.config()[:app] == :mf_exam do
      helper = Path.join(__DIR__, "receipt_fixture.sh")

      default =
        Path.expand("../../med_ex/core/med_core/test/fixtures/receipt_vectors_v2.json", __DIR__)

      command =
        ~S(source "$1"; medex_receipt_fixture "$2" || exit $?; printf '%s' "$MEDEX_RECEIPT_VECTORS")

      case System.cmd("bash", ["-c", command, "fixture", helper, default], stderr_to_stdout: true) do
        {path, 0} -> System.put_env("MEDEX_RECEIPT_VECTORS", path)
        {message, _} -> Mix.raise(message)
      end
    end
  end

  defp credo(args) do
    unless Enum.all?(args, &(&1 == "--strict")),
      do:
        Mix.raise("Workspace Credo is always strict and complete; use the leaf for focused lint")

    prepare_dependencies()
    expected = sources()
    unless expected != [], do: Mix.raise("No source files to analyze")
    {:ok, _} = Application.ensure_all_started(:credo)
    exec = Credo.run(["--strict", "--no-color" | expected])
    actual = Credo.Execution.get_source_files(exec) |> Enum.map(& &1.filename)
    coverage!(expected, actual)
    status = Credo.Execution.get_exit_status(exec)
    unless status == 0 and not exec.halted, do: Mix.raise("Strict Credo failed (#{status})")
    IO.puts("COVERAGE credo #{Mix.Project.config()[:app]} #{length(expected)} exact source files")
  end

  def coverage!(expected, actual) do
    normalize = fn paths -> paths |> Enum.map(&Path.expand/1) |> MapSet.new() end

    unless expected != [] and normalize.(expected) == normalize.(actual),
      do: Mix.raise("Credo source inventory is empty or incomplete")
  end

  defp dialyzer(args) do
    native("compile", ["--warnings-as-errors"])
    beams = Path.wildcard(Path.join(Mix.Project.compile_path(), "*.beam"))
    unless beams != [], do: Mix.raise("No application BEAM files to analyze")
    IO.puts("COVERAGE dialyzer #{Mix.Project.config()[:app]} #{length(beams)} own BEAM files")
    native("dialyzer", args)
  end

  def sources do
    patterns =
      case Mix.Project.config()[:app] do
        :med_ex ->
          ~w(mix.exs .formatter.exs .credo.exs core/*/{mix,.formatter}.exs core/*/{lib,test}/**/*.{ex,exs} test/**/*.{ex,exs} build_support/**/*.{ex,exs} tools/cli_recorder.exs tools/maintainer/**/*.{ex,exs})

        @coordinator ->
          ~w(mix.exs .formatter.exs .credo.exs {config,build_support,ops,examples,tools}/**/*.{ex,exs})

        _ ->
          ~w(mix.exs .formatter.exs .credo.exs {lib,test,config,integration,build_support}/**/*.{ex,exs})
      end

    patterns
    |> Enum.flat_map(&Path.wildcard(&1, match_dot: true))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(
      &Enum.any?(Path.split(&1), fn part -> part in ["deps", "_build", "tmp", ".git"] end)
    )
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp prepare_dependencies do
    Mix.Task.reenable("loadpaths")
    Mix.Task.reenable("deps.loadpaths")
    Mix.Task.run("loadpaths")
  end

  defp in_environment(env, task, args) do
    case child(env, task, args) do
      0 -> :ok
      status -> Mix.raise("#{task} failed (#{status})")
    end
  end

  defp child(env, task, args) do
    argv = [@script, task | args]

    {_output, status} =
      System.cmd("elixir", argv,
        env: [{"MIX_ENV", env}],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    status
  end
end
