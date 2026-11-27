defmodule MedFabric.DetachedArtifacts do
  @moduledoc false
  import Bitwise

  @family ~w(med_ex med_ex_opus med_ex_rtc mf_exam mf_handheld mf_preview)
  @private ~w(med_core med_capture med_ex_maintainer mf_domain mf_store mf_interop med_fabric_workspace weld mix_workspace_ops blitz)
  @roles %{
    "exam" => ~w(med_ex mf_exam),
    "handheld" => ~w(med_ex mf_handheld),
    "preview" => ~w(med_ex med_ex_opus med_ex_rtc mf_preview),
    "combined" => @family
  }

  def main(["inputs", matrix_path, manifest_path, output]) do
    result = inputs!(matrix_path, manifest_path, Path.dirname(output))
    File.write!(output, JSON.encode!(result), [:exclusive])
  end

  def main(["installed", inputs_path, consumer, role, output]) do
    result = installed!(read_json!(inputs_path), consumer, role)
    File.write!(output, JSON.encode!(result), [:exclusive])
  end

  def main(["registry", inputs_path, url, output]) do
    result = registry!(read_json!(inputs_path), url)
    File.write!(output, JSON.encode!(result), [:exclusive])
  end

  def main(_),
    do:
      raise(
        "Use detached_artifacts.exs inputs MATRIX MANIFEST OUTPUT or installed INPUTS CONSUMER ROLE OUTPUT"
      )

  def inputs!(matrix_path, manifest_path, work) do
    matrix = read_json!(matrix_path)
    manifest = read_json!(manifest_path)
    entries = Map.fetch!(manifest, "packages")

    ensure!(
      manifest["schema"] == "medfabric.detached_inputs.v2",
      "Invalid detached artifact manifest schema"
    )

    ensure!(
      manifest["registry"] in ["candidate", "official"],
      "Declare candidate or official registry evidence"
    )

    ensure!(
      is_map(entries) and Enum.sort(Map.keys(entries)) == Enum.sort(@family),
      "Provide exactly the six public archives"
    )

    versions = Map.new(matrix["packages"], &{&1["name"], &1})
    ensure!(Enum.sort(Map.keys(versions)) == Enum.sort(@family), "Invalid release matrix")
    directory = Path.dirname(Path.expand(manifest_path))

    packages = Map.new(@family, &verified_package!(&1, entries, versions, directory, work))

    for names <- [~w(med_ex med_ex_opus med_ex_rtc), ~w(mf_exam mf_handheld mf_preview)] do
      ensure!(
        length(Enum.uniq(Enum.map(names, &packages[&1]["source_revision"]))) == 1,
        "Freeze one source revision per repository"
      )
    end

    %{
      "schema" => "medfabric.detached_verified.v2",
      "registry" => manifest["registry"],
      "manifest_sha256" => sha(File.read!(manifest_path)),
      "packages" => packages
    }
  end

  defp verified_package!(name, entries, versions, directory, work) do
    entry = Map.fetch!(entries, name)
    declaration = Map.fetch!(versions, name)

    allowed =
      if declaration["build"] == "weld",
        do: ~w(archive sha256 source_revision build prepared_release),
        else: ~w(archive sha256 source_revision build)

    ensure!(
      is_map(entry) and Enum.sort(Map.keys(entry)) == Enum.sort(allowed),
      "Invalid artifact identity for #{name}"
    )

    ensure!(entry["build"] == declaration["build"], "Wrong construction for #{name}")

    ensure!(
      hex?(entry["sha256"], 64) and hex?(entry["source_revision"], 40),
      "Invalid archive/source digest for #{name}"
    )

    archive = input_path!(entry["archive"], directory)

    ensure!(
      sha(File.read!(archive)) == entry["sha256"],
      "Archive checksum differs for #{name}"
    )

    prepared = prepared_archive!(entry, declaration, name, archive, directory)

    {metadata, files} = archive!(archive, name, work)

    ensure!(
      metadata["name"] == name and metadata["app"] == name and
        metadata["version"] == declaration["version"],
      "Wrong Hex identity for #{name}"
    )

    requirements = requirements!(metadata["requirements"])
    verify_requirements!(name, requirements, versions)

    {name,
     %{
       "version" => declaration["version"],
       "archive" => archive,
       "sha256" => entry["sha256"],
       "source_revision" => entry["source_revision"],
       "build" => entry["build"],
       "prepared" => prepared,
       "requirements" => requirements,
       "files" => files
     }}
  end

  defp prepared_archive!(%{"build" => "weld"} = entry, declaration, name, archive, directory) do
    path = input_path!(entry["prepared_release"], directory)
    release = read_json!(path)
    verify_prepared!(release, name, declaration["version"], entry, archive)

    %{"identity" => release["bundle_id"], "release_sha256" => sha(File.read!(path))}
  end

  defp prepared_archive!(_, _, _, _, _), do: nil

  defp verify_prepared!(release, name, version, entry, archive) do
    ensure!(
      release["schema"] == "weld.bundle/2" and release["artifact"] == name and
        release["package"] == name and release["version"] == version and
        release["layout"] == if(name == "med_ex", do: "components", else: "flat") and
        hex?(release["bundle_id"], 64) and prepared_archive_matches?(release, entry, archive),
      "Prepared Weld identity does not own the exact #{name} archive"
    )
  end

  defp prepared_archive_matches?(release, entry, archive) do
    get_in(release, ["source", "commit"]) == entry["source_revision"] and
      release["archive_sha256"] == entry["sha256"] and
      get_in(release, ["files", "package"]) == %{
        "path" => "package.tar",
        "sha256" => entry["sha256"],
        "size" => File.stat!(archive).size
      }
  end

  defp verify_requirements!(name, requirements, versions) do
    ensure!(
      name != "med_ex" or map_size(requirements) == 0,
      "Base archive must have no runtime dependencies"
    )

    expected =
      case name do
        name when name in ["mf_exam", "mf_handheld"] -> ["med_ex"]
        "mf_preview" -> ~w(med_ex med_ex_opus med_ex_rtc)
        _ -> []
      end

    actual = Map.keys(requirements) |> Enum.filter(&(&1 in @family)) |> Enum.sort()
    ensure!(actual == Enum.sort(expected), "Wrong ecosystem dependency closure for #{name}")
    Enum.each(requirements, &verify_requirement!(name, &1, versions))
  end

  defp verify_requirement!(name, {dependency, options}, versions) do
    ensure!(
      dependency not in @private and options["repository"] in [nil, "hexpm"] and
        is_binary(options["requirement"]) and
        String.starts_with?(options["requirement"], "~> ") and
        Enum.all?(~w(path git github ref subdir override), &(not Map.has_key?(options, &1))),
      "Nonpublic or non-Hex requirement in #{name}"
    )

    if dependency in @family do
      ensure!(
        options["requirement"] == versions[dependency]["requirement"],
        "Unbounded or incorrect family requirement in #{name}"
      )
    end
  end

  def installed!(inputs, consumer, role) do
    expected = Map.fetch!(@roles, role)
    {lock, []} = Code.eval_file(Path.join(consumer, "mix.lock"))
    ensure!(is_map(lock), "Invalid installed lock")

    family =
      Map.keys(lock) |> Enum.map(&to_string/1) |> Enum.filter(&(&1 in @family)) |> Enum.sort()

    ensure!(family == Enum.sort(expected), "Unexpected installed family closure for #{role}")

    ensure!(
      Enum.all?(Map.keys(lock), &(to_string(&1) not in @private)),
      "Private/tooling package in installed lock"
    )

    packages =
      Map.new(expected, fn name ->
        package = inputs["packages"][name]
        app = String.to_existing_atom(name)

        case Map.fetch!(lock, app) do
          {:hex, ^app, version, _inner, _builders, _requirements, "hexpm", outer} ->
            ensure!(
              version == package["version"] and outer == package["sha256"],
              "Installed Hex checksum differs for #{name}"
            )

          _ ->
            raise "Expected an ordinary Hex installation for #{name}"
        end

        root = Path.join([consumer, "deps", name])

        ensure!(
          File.lstat!(root).type == :directory,
          "Installed package is not detached: #{name}"
        )

        for {relative, entry} <- package["files"] do
          path = Path.join(root, relative)

          ensure!(
            File.lstat!(path).type == :regular and File.stat!(path).size == entry["bytes"] and
              sha(File.read!(path)) == entry["sha256"] and
              band(File.stat!(path).mode, 0o111) == entry["executable"],
            "Installed file differs: #{name}/#{relative}"
          )
        end

        {name, Map.take(package, ~w(version sha256 source_revision build prepared))}
      end)

    %{
      "role" => role,
      "packages" => packages,
      "lock_sha256" => sha(File.read!(Path.join(consumer, "mix.lock")))
    }
  end

  def registry!(inputs, url) do
    ensure!(
      is_binary(url) and byte_size(url) in 1..2048 and String.valid?(url) and
        not Regex.match?(~r/\s/u, url),
      "Invalid registry URL"
    )

    uri = URI.parse(url)

    host =
      if is_binary(uri.host),
        do: uri.host |> String.downcase() |> String.trim_trailing("."),
        else: ""

    ensure!(
      host != "" and uri.userinfo == nil and uri.query == nil and uri.fragment == nil,
      "Registry URL must not contain embedded credentials or query data"
    )

    verify_registry_origin!(inputs["registry"], url, uri.scheme, host)
    %{"kind" => inputs["registry"], "url" => url}
  end

  defp verify_registry_origin!("official", url, _, _) do
    ensure!(
      url == "https://repo.hex.pm",
      "Official proof requires the official Hex registry origin"
    )
  end

  defp verify_registry_origin!("candidate", _, scheme, host) do
    ensure!(
      host != "repo.hex.pm" and
        (scheme == "https" or (scheme == "http" and host in ["127.0.0.1", "localhost"])),
      "Candidate proof requires an explicitly configured signed registry"
    )
  end

  defp verify_registry_origin!(_, _, _, _), do: raise("Unknown registry proof kind")

  defp archive!(archive, name, work) do
    {:ok, outer} = :erl_tar.extract(String.to_charlist(archive), [:memory])
    outer = Map.new(outer, fn {path, bytes} -> {to_string(path), bytes} end)
    metadata_path = Path.join(work, "#{name}-metadata.config")
    File.write!(metadata_path, Map.fetch!(outer, "metadata.config"), [:exclusive])
    {:ok, metadata} = :file.consult(String.to_charlist(metadata_path))
    metadata = Map.new(metadata, fn {key, value} -> {to_string(key), value} end)
    gzip = Map.fetch!(outer, "contents.tar.gz")
    {:ok, table} = :erl_tar.table({:binary, gzip}, [:compressed, :verbose])

    modes =
      Map.new(table, fn {path, type, _bytes, _time, mode, _uid, _gid} ->
        relative = path |> to_string() |> String.trim_trailing("/")

        ensure!(
          type in [:regular, :directory] and safe_path?(relative),
          "Unsafe archived path in #{name}"
        )

        {relative, band(mode, 0o111)}
      end)

    ensure!(map_size(modes) == length(table), "Duplicate archived path in #{name}")
    {:ok, contents} = :erl_tar.extract({:binary, gzip}, [:compressed, :memory])

    files =
      Map.new(contents, fn {path, bytes} ->
        relative = to_string(path)
        ensure!(safe_path?(relative), "Unsafe archived file in #{name}")

        {relative,
         %{
           "bytes" => byte_size(bytes),
           "sha256" => sha(bytes),
           "executable" => Map.fetch!(modes, relative)
         }}
      end)

    ensure!(
      map_size(files) == length(contents) and Map.has_key?(files, "mix.exs"),
      "Duplicate or missing archived source in #{name}"
    )

    declared =
      metadata["files"] |> Enum.map(&(to_string(&1) |> String.trim_trailing("/"))) |> Enum.sort()

    ensure!(
      length(Enum.uniq(declared)) == length(declared) and
        Enum.all?(declared, &Map.has_key?(modes, &1)) and
        Enum.sort(Enum.filter(declared, &Map.has_key?(files, &1))) == Enum.sort(Map.keys(files)),
      "Hex package inventory differs for #{name}"
    )

    {metadata, files}
  end

  defp requirements!(entries) do
    pairs =
      Enum.map(entries, fn
        {name, options} ->
          {to_string(name), Map.new(options, fn {k, v} -> {to_string(k), v} end)}

        options ->
          map = Map.new(options, fn {k, v} -> {to_string(k), v} end)
          {Map.fetch!(map, "name"), map}
      end)

    ensure!(map_size(Map.new(pairs)) == length(pairs), "Duplicate Hex requirement")
    Map.new(pairs)
  end

  defp input_path!(value, directory) do
    ensure!(is_binary(value) and value != "", "Missing artifact path")
    path = Path.expand(value, directory)
    ensure!(File.lstat!(path).type == :regular, "Artifact inputs must be regular files")
    path
  end

  defp safe_path?(path) do
    Path.type(path) == :relative and path != "" and
      not String.contains?(path, ["\\", "\0"]) and
      Enum.all?(
        String.split(String.trim_trailing(path, "/"), "/"),
        &(&1 not in ["", ".", "..", ".git", "deps", "_build", ".mix_sources.json"])
      )
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()

  defp hex?(value, size),
    do: is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp ensure!(true, _), do: :ok
  defp ensure!(_, reason), do: raise(reason)
end

unless System.get_env("MF_DETACHED_ARTIFACTS_TEST") == "1",
  do: MedFabric.DetachedArtifacts.main(System.argv())
