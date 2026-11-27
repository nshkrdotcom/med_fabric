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
          {"files", ["mix.exs"]}
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
            package,
            "mix.exs"
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
                "artifact" => name,
                "identity" => String.duplicate("b", 64),
                "source_revision" => entry["source_revision"],
                "integrity" => %{"archive_sha256" => entry["sha256"]}
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

  test "the six actual archive inventories and prepared identities are recorded", c do
    inputs = Artifacts.inputs!(@matrix, c.manifest, c.work)
    assert map_size(inputs["packages"]) == 6
    assert inputs["packages"]["mf_exam"]["prepared"]["identity"] == String.duplicate("b", 64)
    assert inputs["packages"]["mf_preview"]["files"]["mix.exs"]["bytes"] > 0
    assert inputs["packages"]["med_ex_opus"]["prepared"] == nil
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
      |> Map.put("source_revision", String.duplicate("c", 40))

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

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
