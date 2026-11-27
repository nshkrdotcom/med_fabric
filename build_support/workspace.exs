defmodule MedFabric.Build.Workspace do
  @moduledoc false
  @tasks ~w(setup test credo dialyzer quality docs)
  @projects ~w(core/domain core/store core/interop apps/exam apps/handheld apps/preview)
  @boundaries ~w(. tools/maintainer)
  @root Path.expand("..", __DIR__)
  @script Path.join(__DIR__, "run_project_qc.exs")

  def aliases do
    Enum.map(@tasks, fn task -> {String.to_atom(task), &run(task, &1)} end)
  end

  # The SDK root is a real app. Its child invokes native task modules, never
  # the root aliases. Fabric's empty coordinator is not an analysis target.
  def projects(task) when task in ["setup", "quality"],
    do: Enum.uniq(@projects ++ @boundaries)

  def projects("docs"), do: Enum.uniq(["." | @projects])
  def projects(_task), do: @projects

  def run(task, args) do
    {opts, forwarded} = options(args, %{jobs: 2, projects: [], locked: false, release: false})
    selected = select(task, opts.projects, forwarded)
    if task in ["setup", "quality"] and forwarded != [],
      do: Mix.raise("#{task} accepts only --jobs, --project, --locked and --release")
    if opts.locked and task != "setup", do: Mix.raise("--locked is for mix setup")
    if opts.release and task != "quality", do: Mix.raise("--release is for mix quality")
    check_environment!()
    ensure_tools(task, opts.locked)
    selected = if task == "setup", do: Enum.reject(selected, &(&1 == ".")), else: selected
    extra = if opts.locked, do: ["--locked"], else: []
    extra = if opts.release, do: ["--release" | extra], else: extra

    commands =
      Enum.map(selected, fn project ->
        apply(Blitz, :command, [[
          id: project,
          command: "elixir",
          args: argv(task, extra ++ forwarded),
          cd: Path.join(@root, project),
          env: %{"MIX_ENV" => "dev", "ERL_FLAGS" => System.get_env("ERL_FLAGS", "+S 4:4")}
        ]])
      end)

    apply(Blitz, :run!, [commands, [max_concurrency: opts.jobs, timeout: :infinity]])
  end

  def argv(task, args),
    do: [@script, task | args]

  def select(task, requested, args) do
    available = projects(task)
    selected = if requested == [], do: default_selection(task, args, available), else: requested

    unless selected != [] and Enum.all?(selected, &(&1 in available)),
      do: Mix.raise("Select --project from: #{Enum.join(available, ", ")}")

    if task != "test" and Enum.any?(args, &(!String.starts_with?(&1, "--"))),
      do: Mix.raise("Unexpected arguments; use a native task from the project directory")

    Enum.uniq(selected)
  end

  defp default_selection("test", args, available) do
    if Enum.any?(args, &String.contains?(&1, [".exs", "/"])) do
      Mix.raise("A Fabric test path requires --project, e.g. --project apps/exam -- test/file_test.exs")
    else
      available
    end
  end

  defp default_selection(_task, _args, available), do: available

  def options([], opts), do: {opts, []}
  def options(["--" | args], opts), do: {opts, args}

  def options(["--project", project | args], opts),
    do: options(args, %{opts | projects: opts.projects ++ [project]})

  def options(["--jobs", number | args], opts) do
    case Integer.parse(number) do
      {jobs, ""} when jobs in 1..4 -> options(args, %{opts | jobs: jobs})
      _ -> Mix.raise("--jobs must be between 1 and 4")
    end
  end

  def options(["--locked" | args], opts), do: options(args, %{opts | locked: true})
  def options(["--release" | args], opts), do: options(args, %{opts | release: true})
  def options(args, opts), do: {opts, args}

  defp ensure_tools("setup", locked?) do
    args = if locked?, do: ["--check-locked"], else: []
    Mix.Task.run("deps.get", args)
    {_output, status} = System.cmd("mix", ["deps.get" | args],
      env: [{"MIX_ENV", "test"}], into: IO.stream(:stdio, :line), stderr_to_stdout: true)
    unless status == 0, do: Mix.raise("Root test dependency bootstrap failed (#{status})")
    Mix.Task.run("deps.compile")
    Mix.Task.run("loadpaths")
  end

  defp ensure_tools(_task, _locked?) do
    Mix.Task.run("loadpaths")
    unless Code.ensure_loaded?(Blitz), do: Mix.raise("Run mix setup to install workspace tools")
  end

  defp check_environment! do
    for name <- ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS),
        System.get_env(name) do
      Mix.raise("Unset #{name}; each project owns its build, dependencies and lock context")
    end
  end
end
