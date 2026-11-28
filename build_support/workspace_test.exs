ExUnit.start()
Mix.start()
Code.require_file("workspace.exs", __DIR__)
Code.require_file("project_qc.exs", __DIR__)

defmodule MedFabric.WorkspaceTest do
  use ExUnit.Case, async: false
  @compile {:no_warn_undefined, Blitz}
  alias MedFabric.Build.{ProjectQC, Workspace}

  test "ordinary root suites and full quality have distinct exact scopes" do
    assert Workspace.projects("test") ==
             ~w(core/domain core/store core/interop apps/exam apps/handheld apps/preview)

    assert Workspace.projects("dialyzer") == Workspace.projects("test")
    refute "." in Workspace.projects("dialyzer")
    assert "." in Workspace.projects("quality")
  end

  test "Fabric test paths require an explicit project" do
    assert_raise Mix.Error, fn -> Workspace.select("test", [], ["test/a_test.exs"]) end
    assert Workspace.select("test", ["apps/exam"], ["test/a_test.exs"]) == ["apps/exam"]
    assert_raise Mix.Error, fn -> Workspace.select("dialyzer", ["."], []) end
  end

  test "workspace options preserve native flags without shell interpolation" do
    defaults = %{projects: [], locked: false, release: false}

    assert {%{projects: ["."], locked: true}, ["--seed", "0"]} =
             Workspace.options(
               ["--project", ".", "--locked", "--", "--seed", "0"],
               defaults
             )

    assert [script, "test", "--seed", "0"] =
             Workspace.argv("test", ["--seed", "0"])

    assert Path.basename(script) == "run_project_qc.exs"
  end

  test "static coverage refuses zero, partial and extra source inventories" do
    assert ProjectQC.coverage!(["one.ex", "two.ex"], ["two.ex", "one.ex"]) == nil

    for {expected, actual} <- [{[], []}, {["one.ex"], []}, {["one.ex"], ["two.ex"]}],
        do: assert_raise(Mix.Error, fn -> ProjectQC.coverage!(expected, actual) end)
  end

  test "native dispatch prepares dependencies without deployment runtime config or root aliases" do
    root = temporary_directory("native-task")

    for dir <- ["lib", "test", "config", "dependency/lib"],
        do: File.mkdir_p!(Path.join(root, dir))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule NativeFixture.MixProject do
      use Mix.Project
      def project do
        [app: :native_fixture, version: "0.0.0", aliases: [test: &bad/1],
         deps: [{:native_dependency, path: "dependency"}]]
      end
      defp bad(_args), do: raise("recursive root alias")
    end
    """)

    File.write!(Path.join(root, "dependency/mix.exs"), """
    defmodule NativeDependency.MixProject do
      use Mix.Project
      def project, do: [app: :native_dependency, version: "0.0.0"]
      def application, do: [mod: {NativeDependency.Application, []}]
    end
    """)

    File.write!(Path.join(root, "dependency/lib/native_dependency.ex"), """
    defmodule NativeDependency do
      defmacro value(), do: quote(do: 42)
    end
    defmodule NativeDependency.Application do
      use Application
      def start(_type, _args), do: Agent.start_link(fn -> :ready end, name: __MODULE__)
    end
    """)

    File.write!(Path.join(root, "lib/native_fixture.ex"), """
    defmodule NativeFixture do
      require NativeDependency
      @configured Application.compile_env(:native_fixture, :compile_probe)
      def value, do: NativeDependency.value()
      def configured, do: @configured
    end
    """)

    File.write!(Path.join(root, "config/config.exs"), """
    import Config
    config :native_fixture, :compile_probe, :compile_time_loaded
    """)

    File.write!(Path.join(root, "config/runtime.exs"), """
    import Config
    if config_env() != :test, do: raise("deployment runtime config loaded during development QC")
    """)

    File.write!(Path.join(root, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(root, "test/real_test.exs"), """
    defmodule NativeFixtureTest do
      use ExUnit.Case
      test "dependency was compiled and its application started" do
        assert NativeFixture.value() == 42
        assert NativeFixture.configured() == :compile_time_loaded
        assert Agent.get(NativeDependency.Application, & &1) == :ready
      end
    end
    """)

    {fetched, fetch_status} =
      System.cmd("mix", ["deps.get"],
        cd: root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert fetch_status == 0, fetched
    assert Path.wildcard(Path.join(root, "_build/**/*.beam")) == []

    {compiled, compile_status} =
      System.cmd("elixir", Workspace.argv("compile", []),
        cd: root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert compile_status == 0, compiled
    refute compiled =~ "deployment runtime config loaded"
    assert Path.wildcard(Path.join(root, "_build/test/**/*.beam")) == []

    {output, status} =
      System.cmd("elixir", Workspace.argv("native_test", ["--seed", "0"]),
        cd: root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Result: 1 passed"
    refute output =~ "recursive root alias"

    assert File.regular?(
             Path.join(
               root,
               "_build/test/lib/native_dependency/ebin/Elixir.NativeDependency.beam"
             )
           )
  end

  test "installed Blitz respects an explicit CPU admission budget" do
    require_blitz!()
    root = temporary_directory("blitz-concurrency")
    worker = Path.join(root, "worker.exs")

    File.write!(worker, """
    [id] = System.argv()
    File.write!(id <> ".started", System.fetch_env!("WORKSPACE_QC_MARKER"))
    wait = fn recur ->
      if File.exists?("release") do
        File.write!(id <> ".done", "ok")
      else
        receive do
        after
          10 -> recur.(recur)
        end
      end
    end
    wait.(wait)
    """)

    commands =
      for id <- 1..4 do
        Blitz.command(
          id: "worker-#{id}",
          command: System.find_executable("elixir"),
          args: [worker, Integer.to_string(id)],
          cd: root,
          env: %{"WORKSPACE_QC_MARKER" => "exact-env", "ERL_FLAGS" => "+S 2:2"}
        )
      end

    run =
      Task.async(fn -> Blitz.run!([%{commands: commands}], budget: [cpu: 2], timeout: 15_000) end)

    try do
      wait_for(fn -> length(Path.wildcard(Path.join(root, "*.started"))) >= 2 end)
      assert Task.yield(run, 200) == nil
      started = Path.wildcard(Path.join(root, "*.started"))
      assert length(started) == 2
      assert Enum.all?(started, &(File.read!(&1) == "exact-env"))
      File.write!(Path.join(root, "release"), "go")
      Task.await(run, 15_000)

      assert Enum.sort(Path.wildcard(Path.join(root, "*.done"))) ==
               Enum.map(1..4, &Path.join(root, "#{&1}.done"))

      assert Enum.all?(
               Path.wildcard(Path.join(root, "*.started")),
               &(File.read!(&1) == "exact-env")
             )
    after
      File.write!(Path.join(root, "release"), "cleanup")
      if Process.alive?(run.pid), do: Task.shutdown(run, 15_000)
    end
  end

  test "installed Blitz propagates a real child failure with its command identity" do
    require_blitz!()
    root = temporary_directory("blitz-failure")

    command =
      Blitz.command(
        id: "expected-child-failure",
        command: System.find_executable("elixir"),
        args: ["-e", "System.halt(7)"],
        cd: root,
        env: %{"ERL_FLAGS" => "+S 2:2"}
      )

    error =
      assert_raise Blitz.Error, fn ->
        Blitz.run!([%{commands: [command]}], timeout: 15_000)
      end

    assert Exception.message(error) =~ "expected-child-failure"
    assert Exception.message(error) =~ "exit: 7"
  end

  defp require_blitz! do
    __DIR__
    |> Path.join("../_build/dev/lib/*/ebin")
    |> Path.wildcard()
    |> Enum.each(&Code.prepend_path/1)

    assert Code.ensure_loaded?(Blitz),
           "Real Blitz is required for workspace tests; run mix setup in this root first"

    assert {:ok, _} = Application.ensure_all_started(:blitz)
  end

  defp temporary_directory(prefix) do
    root =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp wait_for(predicate, remaining \\ 500) do
    cond do
      predicate.() ->
        :ok

      remaining == 0 ->
        flunk("Timed out waiting for the real Blitz workers to start")

      true ->
        receive do
        after
          10 -> wait_for(predicate, remaining - 1)
        end
    end
  end
end
