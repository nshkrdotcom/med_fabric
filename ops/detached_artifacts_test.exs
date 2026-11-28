System.put_env("MF_DETACHED_ARTIFACTS_TEST", "1")
Code.require_file("detached_artifacts.exs", __DIR__)
System.delete_env("MF_DETACHED_ARTIFACTS_TEST")
ExUnit.start()

defmodule MedFabric.DetachedArtifactsTest do
  use ExUnit.Case, async: true
  alias MedFabric.DetachedArtifacts, as: Artifacts
  @moduletag :tmp_dir
  @matrix Path.expand("../build_support/release_matrix.json", __DIR__)

  setup %{tmp_dir: root} do
    matrix = @matrix |> File.read!() |> JSON.decode!()

    packages =
      Map.new(matrix["packages"], fn declaration ->
        name = declaration["name"]
        package = Path.join(root, name)
        File.mkdir!(package)
        File.write!(Path.join(package, "mix.exs"), "# Exact archived source for #{name}\n")
        File.chmod!(Path.join(package, "mix.exs"), 0o644)

        {files, directories} = source_files(name, package)

        requirements =
          case name do
            "mf_preview" -> ~w(med_ex med_ex_opus med_ex_rtc)
            name when name in ~w(mf_exam mf_handheld) -> ["med_ex"]
            _ -> []
          end

        requirements =
          for dependency <- requirements do
            version = Enum.find(matrix["packages"], &(&1["name"] == dependency))["requirement"]

            {dependency,
             [
               {"requirement", version},
               {"optional", false},
               {"app", dependency},
               {"repository", "hexpm"}
             ]}
          end

        metadata = [
          {"name", name},
          {"app", name},
          {"version", declaration["version"]},
          {"requirements", requirements},
          {"files", files ++ directories}
        ]

        File.write!(
          Path.join(package, "metadata.config"),
          Enum.map(metadata, &:io_lib.format(~c"~tp.~n", [&1]))
        )

        {_, 0} =
          System.cmd("tar", [
            "-czf",
            Path.join(package, "contents.tar.gz"),
            "-C",
            package | files
          ])

        archive = Path.join(root, "#{name}.tar")

        {_, 0} =
          System.cmd("tar", ["-cf", archive, "-C", package, "metadata.config", "contents.tar.gz"])

        entry = %{
          "archive" => Path.basename(archive),
          "sha256" => sha(File.read!(archive)),
          "source_revision" => String.duplicate("a", 40),
          "build" => declaration["build"]
        }

        entry =
          if declaration["build"] == "weld" do
            release = "#{name}-release.json"

            File.write!(
              Path.join(root, release),
              JSON.encode!(%{
                "schema" => "weld.bundle/2",
                "artifact" => name,
                "package" => name,
                "version" => declaration["version"],
                "layout" => if(name == "med_ex", do: "components", else: "flat"),
                "bundle_id" => String.duplicate("b", 64),
                "source" => %{"commit" => entry["source_revision"]},
                "archive_sha256" => entry["sha256"],
                "files" => %{
                  "package" => %{
                    "path" => "package.tar",
                    "sha256" => entry["sha256"],
                    "size" => File.stat!(archive).size
                  }
                }
              })
            )

            Map.put(entry, "prepared_release", release)
          else
            entry
          end

        {name, entry}
      end)

    manifest = Path.join(root, "manifest.json")

    File.write!(
      manifest,
      JSON.encode!(%{
        "schema" => "medfabric.detached_inputs.v2",
        "registry" => "candidate",
        "packages" => packages
      })
    )

    work = Path.join(root, "verification")
    File.mkdir!(work)
    %{root: root, manifest: manifest, work: work}
  end

  defp source_files("med_ex_opus", package) do
    relative = "lib/med_ex/opus/provider.ex"
    path = Path.join(package, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# Packed without explicit directory entries\n")
    {["mix.exs", relative], ~w(lib lib/med_ex lib/med_ex/opus)}
  end

  defp source_files(_, _), do: {["mix.exs"], []}

  test "the six actual archive inventories and prepared identities are recorded", c do
    inputs = Artifacts.inputs!(@matrix, c.manifest, c.work)
    assert map_size(inputs["packages"]) == 6
    assert inputs["packages"]["mf_exam"]["prepared"]["identity"] == String.duplicate("b", 64)
    assert inputs["packages"]["mf_preview"]["files"]["mix.exs"]["bytes"] > 0
    assert inputs["packages"]["med_ex_opus"]["prepared"] == nil

    assert Map.keys(inputs["packages"]["med_ex_opus"]["files"]) |> Enum.sort() ==
             ~w(lib/med_ex/opus/provider.ex mix.exs)
  end

  test "a declared directory needs an archive entry or an archived descendant", c do
    package = Path.join(c.root, "med_ex_opus")
    metadata = Path.join(package, "metadata.config")
    {:ok, entries} = :file.consult(String.to_charlist(metadata))
    {"files", files} = List.keyfind(entries, "files", 0)
    entries = List.keyreplace(entries, "files", 0, {"files", ["not-present" | files]})

    File.write!(metadata, Enum.map(entries, &:io_lib.format(~c"~tp.~n", [&1])))
    archive = Path.join(c.root, "med_ex_opus.tar")

    {_, 0} =
      System.cmd("tar", ["-cf", archive, "-C", package, "metadata.config", "contents.tar.gz"])

    manifest =
      c.manifest
      |> File.read!()
      |> JSON.decode!()
      |> put_in(["packages", "med_ex_opus", "sha256"], sha(File.read!(archive)))

    File.write!(c.manifest, JSON.encode!(manifest))

    assert_raise RuntimeError, ~r/Hex package inventory differs for med_ex_opus/, fn ->
      Artifacts.inputs!(@matrix, c.manifest, c.work)
    end
  end

  test "a matching version cannot substitute different tar bytes", c do
    File.write!(Path.join(c.root, "med_ex.tar"), "changed", [:append])

    assert_raise RuntimeError, ~r/Archive checksum differs/, fn ->
      Artifacts.inputs!(@matrix, c.manifest, c.work)
    end
  end

  test "a Weld release identity must bind the supplied archive and source revision", c do
    release = Path.join(c.root, "med_ex-release.json")

    changed =
      release
      |> File.read!()
      |> JSON.decode!()
      |> put_in(["source", "commit"], String.duplicate("c", 40))

    File.write!(release, JSON.encode!(changed))

    assert_raise RuntimeError, ~r/Prepared Weld identity/, fn ->
      Artifacts.inputs!(@matrix, c.manifest, c.work)
    end
  end

  test "installed lock checksums and individual source files must match", c do
    inputs = Artifacts.inputs!(@matrix, c.manifest, c.work)
    consumer = Path.join(c.root, "consumer")
    File.mkdir!(consumer)

    lock =
      for name <- ~w(med_ex mf_exam), into: %{} do
        destination = Path.join([consumer, "deps", name])
        File.mkdir_p!(destination)
        File.cp!(Path.join([c.root, name, "mix.exs"]), Path.join(destination, "mix.exs"))
        File.chmod!(Path.join(destination, "mix.exs"), 0o644)
        app = String.to_atom(name)
        package = inputs["packages"][name]

        {app,
         {:hex, app, package["version"], String.duplicate("d", 64), [:mix], [], "hexpm",
          package["sha256"]}}
      end

    File.write!(Path.join(consumer, "mix.lock"), inspect(lock, limit: :infinity))
    assert %{"role" => "exam"} = Artifacts.installed!(inputs, consumer, "exam")
    File.write!(Path.join([consumer, "deps", "mf_exam", "mix.exs"]), "altered")

    assert_raise RuntimeError, ~r/Installed file differs/, fn ->
      Artifacts.installed!(inputs, consumer, "exam")
    end

    File.cp!(
      Path.join([c.root, "mf_exam", "mix.exs"]),
      Path.join([consumer, "deps", "mf_exam", "mix.exs"])
    )

    wrong = Map.update!(lock, :mf_exam, &put_elem(&1, 7, String.duplicate("e", 64)))
    File.write!(Path.join(consumer, "mix.lock"), inspect(wrong, limit: :infinity))

    assert_raise RuntimeError, ~r/Installed Hex checksum differs/, fn ->
      Artifacts.installed!(inputs, consumer, "exam")
    end
  end

  test "candidate repository bytes cannot be labelled official registry proof" do
    assert %{"kind" => "official"} =
             Artifacts.registry!(%{"registry" => "official"}, "https://repo.hex.pm")

    assert %{"kind" => "candidate"} =
             Artifacts.registry!(%{"registry" => "candidate"}, "http://127.0.0.1:4567")

    assert_raise RuntimeError, ~r/official Hex registry origin/, fn ->
      Artifacts.registry!(%{"registry" => "official"}, "http://127.0.0.1:4567")
    end

    assert_raise RuntimeError, ~r/embedded credentials/, fn ->
      Artifacts.registry!(%{"registry" => "candidate"}, "https://secret@example.test")
    end

    for origin <- [
          "https://repo.hex.pm/",
          "https://REPO.HEX.PM./registry",
          "https://repo.hex.pm:443"
        ] do
      assert_raise RuntimeError, ~r/explicitly configured signed registry/, fn ->
        Artifacts.registry!(%{"registry" => "candidate"}, origin)
      end
    end

    assert_raise RuntimeError, ~r/Invalid registry URL/, fn ->
      Artifacts.registry!(%{"registry" => "candidate"}, "https://example.test /registry")
    end
  end

  test "direct packages shipping a mix.lock fail archive policy even when listed in metadata",
       c do
    matrix = @matrix |> File.read!() |> JSON.decode!()

    for target <- ~w(mf_handheld mf_preview) do
      work = Path.join(c.root, "lock-policy-" <> target)
      File.mkdir_p!(work)
      archive = Path.join(work, target <> ".tar")

      reqs =
        case target do
          "mf_preview" -> ~w(med_ex med_ex_opus med_ex_rtc)
          "mf_handheld" -> ["med_ex"]
        end

      requirements =
        for dependency <- reqs do
          version = Enum.find(matrix["packages"], &(&1["name"] == dependency))["requirement"]

          {dependency,
           [
             {"requirement", version},
             {"optional", false},
             {"app", dependency},
             {"repository", "hexpm"}
           ]}
        end

      metadata =
        [
          {"name", target},
          {"app", target},
          {"version", "0.3.0"},
          {"requirements", requirements},
          {"files", ["mix.exs", "mix.lock"]}
        ]
        |> Enum.map(&:io_lib.format(~c"~tp.~n", [&1]))
        |> IO.iodata_to_binary()

      contents_path = Path.join(work, "contents.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(contents_path),
          [{~c"mix.exs", "defmodule X, do: :ok\n"}, {~c"mix.lock", "%{}\n"}],
          [:compressed]
        )

      contents = File.read!(contents_path)

      :ok =
        :erl_tar.create(String.to_charlist(archive), [
          {~c"metadata.config", metadata},
          {~c"contents.tar.gz", contents}
        ])

      manifest =
        c.manifest
        |> File.read!()
        |> JSON.decode!()
        |> put_in(["packages", target, "archive"], archive)
        |> put_in(["packages", target, "sha256"], sha(File.read!(archive)))

      manifest_path = Path.join(c.root, "lock-policy-" <> target <> ".json")
      File.write!(manifest_path, JSON.encode!(manifest))

      assert_raise RuntimeError, ~r/Packaged source lock in #{target}/, fn ->
        Artifacts.inputs!(@matrix, manifest_path, work)
      end
    end
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
