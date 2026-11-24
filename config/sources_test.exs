# Run with plain Elixir: elixir config/sources_test.exs
# This lane evaluates only the committed finite source selector. The repository
# process/consumer lanes separately prove real Mix SCM fetching and compilation.
Mix.start()
Code.require_file("sources.exs", __DIR__)
ExUnit.start()

defmodule MedFabric.BuildSourcesTest do
  use ExUnit.Case, async: false
  alias MedFabric.BuildSources, as: Sources

  @env ~w(MF_MED_EX_PATH MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE)
  @defaults [
    {:med_ex, "~> 0.2.0", override: true, runtime: true},
    {:mf_domain, path: "../../core/domain"},
    {:jason, "~> 1.4"}
  ]

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "mf-sources-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    project = Path.join(root, "apps/exam")
    File.mkdir_p!(project)
    lock = "%{}\n"
    File.write!(Path.join(project, "mix.lock"), lock)
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root, project: project, lock: lock}
  end

  test "absent configuration is exactly the committed defaults with no generated directory", c do
    assert {@defaults, []} == Sources.resolve(@defaults, c.project, c.root)
    refute File.exists?(Path.join(c.root, ".weld"))
    refute File.exists?(Path.join(c.project, "_build"))
    assert File.read!(Path.join(c.project, "mix.lock")) == c.lock
  end

  test "direct, live and full paths each isolate lock, build and dependency roots", c do
    candidates = ["sdk-a", ".weld/live/med_ex", ".weld/full/med_ex/project"]

    paths =
      for candidate <- candidates do
        make_project(c.root, candidate)
        select(c, %{"med_ex" => %{"path" => candidate}})
        {deps, roots} = Sources.resolve(@defaults, c.project, c.root)
        assert {:med_ex, "~> 0.2.0", options} = hd(deps)
        assert options[:path] == Path.join(c.root, candidate)
        assert options[:override] and options[:runtime]
        assert Enum.sort(Keyword.keys(roots)) == [:build_path, :deps_path, :lockfile]

        assert Enum.all?(
                 Keyword.values(roots),
                 &String.starts_with?(&1, c.project <> "/_build/source_contexts/")
               )

        assert roots == elem(Sources.resolve(@defaults, c.project, c.root), 1)
        roots
      end

    assert length(Enum.uniq(paths)) == 3
    assert File.read!(Path.join(c.project, "mix.lock")) == c.lock
    File.rm!(Path.join(c.root, ".mix_sources.json"))
    assert {@defaults, []} == Sources.resolve(@defaults, c.project, c.root)
  end

  test "two Git refs and a Hex choice retain policy and replace only source coordinates", c do
    contexts =
      for ref <- [String.duplicate("a", 40), String.duplicate("b", 40)] do
        select(c, %{"med_ex" => %{"github" => "example/med_ex", "ref" => ref, "subdir" => "sdk"}})

        {[{:med_ex, requirement, options} | _], roots} =
          Sources.resolve(@defaults, c.project, c.root)

        assert requirement == "~> 0.2.0"
        assert options[:ref] == ref and options[:subdir] == "sdk"
        assert options[:override] and options[:runtime]
        refute Keyword.has_key?(options, :path)
        roots
      end

    assert Enum.uniq(contexts) == contexts
    select(c, %{"med_ex" => %{"hex" => "med_ex", "repo" => "hexpm"}})
    {[{:med_ex, _, options} | _], roots} = Sources.resolve(@defaults, c.project, c.root)
    assert options[:hex] == "med_ex" and options[:repo] == "hexpm"
    assert roots not in contexts
    refute Keyword.has_key?(options, :git)
    assert File.read!(Path.join(c.project, "mix.lock")) == c.lock
  end

  test "full content identity and the committed default lock invalidate mutable state", c do
    sdk = make_project(c.root, "sdk")
    marker = Path.join(sdk, "weld.provenance.json")
    select(c, %{"med_ex" => %{"path" => "sdk"}})
    File.write!(marker, JSON.encode!(%{"kind" => "full", "artifact_id" => "first"}))
    {_, first} = Sources.resolve(@defaults, c.project, c.root)
    File.write!(marker, JSON.encode!(%{"kind" => "full", "artifact_id" => "second"}))
    {_, second} = Sources.resolve(@defaults, c.project, c.root)
    assert first != second
    File.write!(Path.join(c.project, "mix.lock"), "%{different: :lock}\n")
    {_, third} = Sources.resolve(@defaults, c.project, c.root)
    assert third != second
    File.write!(marker, JSON.encode!(%{"kind" => "live"}))
    {_, live} = Sources.resolve(@defaults, c.project, c.root)
    File.write!(Path.join(sdk, "lib.ex"), "defmodule ChangedSource do end\n")
    assert live == elem(Sources.resolve(@defaults, c.project, c.root), 1)
  end

  test "recognized inactive provider selections never activate optional media dependencies", c do
    select(c, %{
      "med_ex_opus" => %{"path" => "not-installed-opus"},
      "med_ex_rtc" => %{"path" => "not-installed-rtc"}
    })

    {deps, _roots} = Sources.resolve(@defaults, c.project, c.root)
    assert deps == @defaults
    refute Enum.any?(deps, fn tuple -> elem(tuple, 0) in [:med_ex_opus, :med_ex_rtc] end)
  end

  test "malformed, executable, conflicting and unknown selections fail closed", c do
    bad = [
      %{"surprise_app" => %{"path" => "."}},
      %{"med_ex" => "Code.eval_file(\"anything\")"},
      %{"med_ex" => %{"path" => "absent"}},
      %{"med_ex" => %{"git" => "https://example.invalid/repo", "github" => "x/y", "ref" => "x"}},
      %{"med_ex" => %{"github" => "x/y", "branch" => "main", "tag" => "v1"}},
      %{"med_ex" => %{"github" => "x/y", "ref" => "x", "subdir" => "../escape"}},
      %{"med_ex" => %{"hex" => "med_ex", "runtime" => false}},
      %{"mf_domain" => %{"hex" => "mf_domain"}}
    ]

    for selection <- bad do
      select(c, selection)
      assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
    end

    for bytes <- ["{\"med_ex\":{},\"med_ex\":{}}", "{} {}", "[]"] do
      File.write!(Path.join(c.root, ".mix_sources.json"), bytes)
      assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
    end
  end

  test "legacy candidate flag is isolated and conflicts with a simultaneous selection", c do
    sdk = make_project(c.root, "sdk")
    System.put_env("MF_MED_EX_PATH", sdk)
    {deps, roots} = Sources.resolve(@defaults, c.project, c.root)
    assert elem(hd(deps), 2)[:path] == sdk
    assert length(roots) == 3
    select(c, %{"med_ex" => %{"path" => "sdk"}})
    assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
    System.delete_env("MF_MED_EX_PATH")

    for name <- ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE) do
      System.put_env(name, Path.join(c.root, "shared-state"))
      assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
      System.delete_env(name)
    end
  end

  defp select(c, value),
    do: File.write!(Path.join(c.root, ".mix_sources.json"), JSON.encode!(value))

  defp make_project(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "mix.exs"),
      "defmodule SourceFixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :med_ex, version: \"0.2.0\"]\nend\n"
    )

    path
  end
end
