# Run with plain Elixir: elixir config/sources_test.exs
# This lane evaluates only the committed finite source selector. The repository
# process/consumer lanes separately prove real Mix SCM fetching and compilation.
Mix.start()
Code.require_file("sources.exs", __DIR__)
ExUnit.start()

defmodule MedFabric.BuildSourcesTest do
  use ExUnit.Case, async: false
  alias MedFabric.BuildSources, as: Sources

  @env ~w(MF_MED_EX_PATH MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE
           CFLAGS CC MED_EX_OPUS_TARBALL XDG_CACHE_HOME
           HEX_HOME HEX_MIRROR_URL HEX_TRUSTED_MIRROR_URL MIX_XDG XDG_CONFIG_HOME XDG_DATA_HOME)
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
    System.put_env("HEX_HOME", Path.join(root, "hex"))
    System.put_env("XDG_CONFIG_HOME", Path.join(root, "config"))

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

  test "the default MedEx family uses the published Hex package ranges" do
    assert {:med_ex, "~> 0.3.1", base_opts} = Sources.med_ex_dependency(:med_ex)
    assert base_opts[:hex] == "med_ex"
    assert base_opts[:repo] == "hexpm"
    assert base_opts[:override]

    for {app, requirement} <- [med_ex_opus: "~> 0.2.1", med_ex_rtc: "~> 0.2.1"] do
      assert {^app, ^requirement, options} = Sources.med_ex_dependency(app)
      assert options == [hex: Atom.to_string(app), repo: "hexpm"]
    end
  end

  test "legacy media without a source file isolates all mutable state by profile and Mix environment",
       c do
    profile = [profile: :legacy_media]
    assert {@defaults, []} == Sources.resolve(@defaults, c.project, c.root)
    assert {@defaults, legacy} = Sources.resolve(@defaults, c.project, c.root, profile)
    assert Enum.sort(Keyword.keys(legacy)) == [:build_path, :deps_path, :lockfile]
    assert length(Enum.uniq(Keyword.values(legacy))) == 3
    assert legacy == elem(Sources.resolve(@defaults, c.project, c.root, profile), 1)

    original = Mix.env()

    try do
      Mix.env(if original == :prod, do: :test, else: :prod)
      assert legacy != elem(Sources.resolve(@defaults, c.project, c.root, profile), 1)
    after
      Mix.env(original)
    end

    System.put_env("MIX_DEPS_PATH", Path.join(c.root, "shared"))
    assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root, profile) end
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

    lock = Path.join(sdk, "projection.lock.json")

    File.write!(
      lock,
      JSON.encode!(%{"projection" => %{"verification_files" => ["mix.exs", "asset.js"]}})
    )

    asset = Path.join(sdk, "asset.js")
    File.write!(asset, "old")
    {_, first} = Sources.resolve(@defaults, c.project, c.root)
    # Same bytes count, timestamp and provenance still require a new build root.
    mtime = File.stat!(asset).mtime
    File.write!(asset, "new")
    File.touch!(asset, mtime)
    assert first != elem(Sources.resolve(@defaults, c.project, c.root), 1)

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

  test "mutable paths preserve ordinary source compiles and isolate dependency or ABI changes",
       c do
    sdk = make_project(c.root, "sdk")
    select(c, %{"med_ex" => %{"path" => "sdk"}})
    {_, first} = Sources.resolve(@defaults, c.project, c.root)
    File.write!(Path.join(sdk, "library.ex"), "defmodule Changed do end")
    assert first == elem(Sources.resolve(@defaults, c.project, c.root), 1)

    File.write!(Path.join(sdk, "mix.lock"), "%{new: :dependency}
")
    {_, graph} = Sources.resolve(@defaults, c.project, c.root)
    assert graph != first

    System.put_env("CFLAGS", "-DFABRIC_TEST_ABI=1")
    assert graph != elem(Sources.resolve(@defaults, c.project, c.root), 1)
  end

  test "frozen native inputs invalidate builds even when absent from a stale inventory", c do
    sdk = make_project(c.root, "sdk")
    select(c, %{"med_ex" => %{"path" => "sdk"}})
    File.write!(Path.join(sdk, "weld.provenance.json"), ~s({"kind":"full","artifact_id":"id"}))

    File.write!(
      Path.join(sdk, "projection.lock.json"),
      JSON.encode!(%{"projection" => %{"verification_files" => ["mix.exs"]}})
    )

    for relative <- ["Makefile", "c_src/encoder.c", "c_src/vendor/SHA256SUMS"] do
      {_, before} = Sources.resolve(@defaults, c.project, c.root)
      path = Path.join(sdk, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "first")
      {_, added} = Sources.resolve(@defaults, c.project, c.root)
      refute added == before

      mtime = File.stat!(path).mtime
      File.write!(path, "other")
      File.touch!(path, mtime)
      refute added == elem(Sources.resolve(@defaults, c.project, c.root), 1)
    end
  end

  test "explicit Opus tarball bytes and cache selection invalidate native build identity", c do
    original = Sources.build_identity()
    tarball = Path.join(c.root, "opus.tar.gz")
    File.write!(tarball, "first")
    System.put_env("MED_EX_OPUS_TARBALL", tarball)
    first = Sources.build_identity()
    refute first == original

    mtime = File.stat!(tarball).mtime
    File.write!(tarball, "other")
    File.touch!(tarball, mtime)
    refute first == Sources.build_identity()

    System.delete_env("MED_EX_OPUS_TARBALL")
    System.put_env("XDG_CACHE_HOME", Path.join(c.root, "private-cache"))
    refute original == Sources.build_identity()
  end

  test "relative Opus archive overrides cannot seed a cache identity" do
    System.put_env("MED_EX_OPUS_TARBALL", "../archives/opus.tar.gz")

    assert_raise Mix.Error, ~r/MED_EX_OPUS_TARBALL must be an absolute path/, fn ->
      Sources.build_identity()
    end
  end

  test "absolute Opus archive identities preserve symlink traversal before parent segments", c do
    provider = Path.join(c.root, "provider")
    File.mkdir_p!(Path.join(provider, "nested"))
    File.ln_s!(Path.join(provider, "nested"), Path.join(c.root, "link"))
    consumed = Path.join(provider, "opus.tar.gz")
    lexical = Path.join(c.root, "opus.tar.gz")
    File.write!(consumed, "first")
    File.write!(lexical, "unrelated")
    override = Path.join(c.root, "link") <> "/../opus.tar.gz"
    assert File.read!(override) == "first"
    System.put_env("MED_EX_OPUS_TARBALL", override)
    first = Sources.build_identity()

    File.write!(lexical, "unrelated edit")
    assert first == Sources.build_identity()

    File.write!(consumed, "other")
    refute first == Sources.build_identity()
  end

  test "frozen inventory prevents path escape or mutable symlinks from seeding builds", c do
    sdk = make_project(c.root, "sdk")
    select(c, %{"med_ex" => %{"path" => "sdk"}})
    File.write!(Path.join(sdk, "weld.provenance.json"), ~s({"kind":"full","artifact_id":"id"}))
    lock = Path.join(sdk, "projection.lock.json")

    for file <- ["../secret", "link/file"] do
      if file == "link/file" do
        File.write!(Path.join(c.root, "file"), "outside")
        File.ln_s!(c.root, Path.join(sdk, "link"))
      end

      File.write!(lock, JSON.encode!(%{"projection" => %{"verification_files" => [file]}}))

      assert_raise Mix.Error, ~r/Invalid frozen projection input/, fn ->
        Sources.resolve(@defaults, c.project, c.root)
      end
    end
  end

  test "recognized inactive provider selections never activate optional media dependencies", c do
    select(c, %{
      "med_ex_opus" => %{"path" => "not-installed-opus"},
      "med_ex_rtc" => %{"path" => "not-installed-rtc"}
    })

    {deps, roots} = Sources.resolve(@defaults, c.project, c.root)
    assert deps == @defaults
    assert roots == []
    refute Enum.any?(deps, fn tuple -> elem(tuple, 0) in [:med_ex_opus, :med_ex_rtc] end)
  end

  test "a nested Store shares the data file and its domain selection isolates the outer consumer",
       c do
    domain = make_project(c.root, "domain")
    mix = Path.join(domain, "mix.exs")
    File.write!(mix, String.replace(File.read!(mix), "app: :med_ex", "app: :mf_domain"))
    store = Path.join(c.root, "core/store")
    File.mkdir_p!(store)
    store_defaults = [{:mf_domain, path: "../domain"}, {:postgrex, "~> 0.23"}]
    outer_defaults = [{:mf_store, path: "../../core/store"}]
    select(c, %{"med_ex" => %{"path" => "unused-sdk"}, "mf_domain" => %{"path" => "domain"}})

    assert {[{:mf_domain, [path: ^domain]}, {:postgrex, "~> 0.23"}], [_ | _]} =
             Sources.resolve(store_defaults, store, c.root)

    assert {^outer_defaults, [_ | _]} = Sources.resolve(outer_defaults, c.project, c.root)
    select(c, %{"med_ex" => %{"path" => "unused-sdk"}})
    assert {^store_defaults, []} = Sources.resolve(store_defaults, store, c.root)
    assert {^outer_defaults, []} = Sources.resolve(outer_defaults, c.project, c.root)
  end

  test "private and official repositories with the same Hex name isolate their state", c do
    select(c, %{"med_ex" => %{"hex" => "med_ex", "repo" => "hexpm"}})
    System.put_env("HEX_HOME", Path.join(c.root, "official-hex"))
    {same_dependencies, official} = Sources.resolve(@defaults, c.project, c.root)
    System.put_env("HEX_HOME", Path.join(c.root, "private-hex"))
    assert {^same_dependencies, private} = Sources.resolve(@defaults, c.project, c.root)
    assert private != official
  end

  test "documented Hex mirrors change every context path without retaining credentials", c do
    select(c, %{"med_ex" => %{"hex" => "med_ex", "repo" => "hexpm"}})
    {dependencies, official} = Sources.resolve(@defaults, c.project, c.root)

    for name <- ~w(HEX_MIRROR_URL HEX_TRUSTED_MIRROR_URL) do
      System.put_env(name, "https://first:token@mirror.example.test/packages?signature=one")
      assert {^dependencies, first} = Sources.resolve(@defaults, c.project, c.root)

      for key <- [:lockfile, :deps_path, :build_path], do: assert(first[key] != official[key])

      System.put_env(name, "https://second:changed@mirror.example.test/packages?signature=two")
      assert {^dependencies, ^first} = Sources.resolve(@defaults, c.project, c.root)

      System.put_env(name, "https://mirror.example.test/other-packages")
      assert {^dependencies, changed} = Sources.resolve(@defaults, c.project, c.root)
      for key <- [:lockfile, :deps_path, :build_path], do: assert(changed[key] != first[key])
      System.delete_env(name)
    end
  end

  test "changing a registry URL or signing key in the same Hex home changes isolation", c do
    select(c, %{"med_ex" => %{"hex" => "med_ex", "repo" => "private"}})
    home = Path.join(c.root, "hex")
    File.mkdir_p!(home)
    System.put_env("HEX_HOME", home)
    config = Path.join(home, "hex.config")

    write = fn url, key, auth ->
      terms = [{:repos, %{"private" => %{url: url, public_key: key, auth_key: auth}}}]
      File.write!(config, :io_lib.format(~c"~p.~n", [terms]))
      elem(Sources.resolve(@defaults, c.project, c.root), 1)
    end

    first = write.("https://example.test/one", "signing-one", "secret-one")
    assert first == write.("https://example.test/one", "signing-one", "secret-two")
    second = write.("https://example.test/two", "signing-one", "secret-two")
    assert first != second
    assert second != write.("https://example.test/two", "signing-two", "secret-two")
  end

  test "incompatible literal versions and mismatched Hex identities are rejected", c do
    sdk = make_project(c.root, "sdk")
    mix = Path.join(sdk, "mix.exs")
    File.write!(mix, String.replace(File.read!(mix), "0.2.0", "0.1.0"))
    select(c, %{"med_ex" => %{"path" => "sdk"}})

    assert_raise Mix.Error, ~r/does not satisfy/, fn ->
      Sources.resolve(@defaults, c.project, c.root)
    end

    select(c, %{"med_ex" => %{"hex" => "another_package"}})

    assert_raise Mix.Error, ~r/must match/, fn ->
      Sources.resolve(@defaults, c.project, c.root)
    end
  end

  test "malformed, executable, conflicting and unknown selections fail closed", c do
    bad = [
      %{"surprise_app" => %{"path" => "."}},
      %{"jason" => %{"hex" => "jason"}},
      %{"med_ex" => "Code.eval_file(\"anything\")"},
      %{"med_ex" => %{"path" => "absent"}},
      %{"med_ex" => %{"path" => ""}},
      %{"med_ex" => %{"git" => "https://example.invalid/repo", "github" => "x/y", "ref" => "x"}},
      %{"med_ex" => %{"github" => "not-an-owner-and-repo", "ref" => "x"}},
      %{"med_ex" => %{"github" => "x/y", "branch" => "main", "tag" => "v1"}},
      %{"med_ex" => %{"github" => "x/y", "branch" => "main"}},
      %{"med_ex" => %{"github" => "x/y", "tag" => "v1"}},
      %{"med_ex" => %{"github" => "x/y", "ref" => "main"}},
      %{"med_ex" => %{"github" => "x/y", "ref" => "x", "subdir" => "../escape"}},
      %{"med_ex" => %{"hex" => "med_ex", "runtime" => false}},
      %{"med_ex" => %{"hex" => " "}},
      %{"mf_domain" => %{"hex" => "mf_domain"}}
    ]

    for selection <- bad do
      select(c, selection)
      assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
    end

    for bytes <- ["{\"med_ex\":{},\"med_ex\":{}}", "{} {}", "[]", "{"] do
      File.write!(Path.join(c.root, ".mix_sources.json"), bytes)
      assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
    end
  end

  test "a candidate declaring a different application fails before Mix executes it", c do
    sdk = make_project(c.root, "sdk")
    mix = Path.join(sdk, "mix.exs")
    File.write!(mix, String.replace(File.read!(mix), "app: :med_ex", "app: :some_other_sdk"))
    select(c, %{"med_ex" => %{"path" => "sdk"}})

    assert_raise Mix.Error, ~r/does not declare med_ex/, fn ->
      Sources.resolve(@defaults, c.project, c.root)
    end
  end

  test "legacy candidate flag is isolated and conflicts with a simultaneous selection", c do
    sdk = make_project(c.root, "sdk")
    System.put_env("MF_MED_EX_PATH", sdk)
    {deps, roots} = Sources.resolve(@defaults, c.project, c.root)
    assert elem(hd(deps), 2)[:path] == sdk
    assert length(roots) == 3
    select(c, %{})
    assert_raise Mix.Error, fn -> Sources.resolve(@defaults, c.project, c.root) end
    System.delete_env("MF_MED_EX_PATH")

    select(c, %{"med_ex" => %{"path" => "sdk"}})

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
