defmodule MedFabric.BuildSources do
  @moduledoc false

  @med_ex_apps [:med_ex, :med_ex_opus, :med_ex_rtc]
  @repo_apps ~w(med_ex med_ex_opus med_ex_rtc)
  @git_keys [:github, :git, :ref, :subdir]
  @scm @git_keys ++ ~w(branch tag path in_umbrella sparse submodules depth hex repo organization)a
  @mix_paths ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE)
  @native_env ~w(CC CXX CPPFLAGS CFLAGS CXXFLAGS LDFLAGS ERL_COMPILER_OPTIONS
                 MAKEFLAGS MIX_REBAR3 CMAKE_TOOLCHAIN_FILE PKG_CONFIG_PATH
                 MED_EX_OPUS_TARBALL XDG_CACHE_HOME)
  @trust_env ~w(HEX_UNSAFE_HTTPS HEX_UNSAFE_REGISTRY HEX_NO_VERIFY_REPO_ORIGIN
                HEX_CACERTS_PATH)

  def med_ex_dependency(app) when app in @med_ex_apps do
    requirement =
      case app do
        :med_ex -> "~> 0.4.0"
        :med_ex_opus -> "~> 0.3.0"
        :med_ex_rtc -> "~> 0.3.0"
      end

    options = [hex: Atom.to_string(app), repo: "hexpm"]
    {app, requirement, options}
  end

  # Loaded only by the repository-owned Mix projects.
  def resolve(defaults, project_dir, repo_root) do
    file = Path.join(repo_root, ".mix_sources.json")
    declared = Enum.map(defaults, fn dep -> dep |> elem(0) |> Atom.to_string() end)
    choices = selections!(file)
    active = Map.take(choices, declared)

    deps = Enum.map(defaults, &apply_choice!(&1, active))

    if active == %{} do
      {deps, []}
    else
      {deps, context_paths!(deps, active, Path.expand(project_dir))}
    end
  end

  defp selections!(file) do
    data =
      case File.read(file) do
        {:ok, bytes} -> read_object!(bytes, file)
        {:error, :enoent} -> %{}
        {:error, reason} -> Mix.raise("Cannot read #{file}: #{inspect(reason)}")
      end

    unless Enum.all?(Map.keys(data), &(&1 in @repo_apps)),
      do: Mix.raise("Unknown dependency in #{file}")

    Map.new(data, fn {app, choice} -> {app, source!(choice, Path.dirname(file))} end)
  end

  defp apply_choice!(dep, active) do
    {app, requirement, policy} = split(dep)

    case Map.fetch(active, Atom.to_string(app)) do
      :error ->
        dep

      {:ok, source} ->
        if path = source[:path], do: check_identity!(app, path, requirement)

        if source[:hex] && source[:hex] != Atom.to_string(app) do
          Mix.raise("Selected Hex package must match #{app}")
        end

        if source[:hex] && !match?({:ok, _}, Version.parse_requirement(requirement || "")) do
          Mix.raise("Hex selection requires a committed version requirement for #{app}")
        end

        options = Keyword.drop(policy, @scm) ++ source
        if requirement, do: {app, requirement, options}, else: {app, options}
    end
  end

  defp context_paths!(deps, active, project) do
    for name <- @mix_paths, System.get_env(name) do
      Mix.raise("#{name} conflicts with source isolation; unset it for this invocation")
    end

    normalized =
      Enum.map(deps, fn dep ->
        {app, requirement, options} = split(dep)
        {app, requirement, Enum.sort(options)}
      end)

    paths =
      normalized
      |> Enum.flat_map(fn {app, _requirement, options} ->
        if path = options[:path], do: [{app, path}], else: []
      end)
      |> Kernel.++(for {app, options} <- active, path = options[:path], do: {app, path})
      |> Enum.map(fn {app, path} -> {app, Path.expand(path, project)} end)
      |> Enum.uniq()

    graph = Enum.map(paths, fn {app, path} -> {app, dependency_inputs(path)} end)
    frozen = Enum.map(paths, fn {app, path} -> {app, artifact_identity(path)} end)

    lock = Path.join(project, "mix.lock")
    lock_digest = if File.regular?(lock), do: lock |> File.read!() |> digest(), else: nil
    otp = :erlang.system_info(:otp_release)
    otp_file = Path.join([to_string(:code.root_dir()), "releases", to_string(otp), "OTP_VERSION"])

    otp_version =
      case File.read(otp_file) do
        {:ok, bytes} -> String.trim(bytes)
        _ -> :erlang.system_info(:system_version)
      end

    # Every isolated context can have transitive registry dependencies.
    hex = registry_identity()

    # Resolver inputs can stay stable across a materialization-only asset or source change.
    resolution =
      {project, normalized, Enum.sort(active), Enum.sort(graph), hex, lock_digest,
       System.version(), otp_version, Mix.env(), Mix.target()}

    # Each mutable Mix context remains private. The verified Hex download cache is
    # outside this tree. In particular, native objects are never copied across paths.
    identity = {5, resolution, Enum.sort(frozen), build_identity()}

    context = digest(:erlang.term_to_binary(identity))
    root = Path.join([project, "_build", "source_contexts", context])

    [
      lockfile: Path.join(root, "mix.lock"),
      deps_path: Path.join(root, "deps"),
      build_path: Path.join(root, "build")
    ]
  end

  @doc false
  def build_identity do
    otp_file =
      Path.join([
        to_string(:code.root_dir()),
        "releases",
        to_string(:erlang.system_info(:otp_release)),
        "OTP_VERSION"
      ])

    digest(
      :erlang.term_to_binary({
        System.version(),
        optional_digest(otp_file),
        :erlang.system_info(:system_architecture),
        optional_digest("/etc/os-release"),
        opus_tarball_identity(),
        Enum.map(@native_env, &System.get_env/1)
      })
    )
  end

  defp opus_tarball_identity do
    case System.get_env("MED_EX_OPUS_TARBALL") do
      path when is_binary(path) and path != "" ->
        unless Path.type(path) == :absolute,
          do: Mix.raise("MED_EX_OPUS_TARBALL must be an absolute path")

        # Preserve filesystem traversal through symlinks and `..`, exactly as
        # the provider's Makefile reads this already-absolute override.
        case File.lstat(path) do
          {:ok, %{type: :regular}} -> {path, digest(File.read!(path))}
          _ -> Mix.raise("MED_EX_OPUS_TARBALL must be a readable regular file")
        end

      _ ->
        nil
    end
  end

  @doc false
  def registry_identity do
    home = System.get_env("HEX_HOME", Path.join(System.user_home!(), ".hex")) |> Path.expand()

    mirrors =
      Enum.map(~w(HEX_MIRROR_URL HEX_TRUSTED_MIRROR_URL), fn name ->
        safe_url(System.get_env(name))
      end)

    # Hex's configuration is local Erlang terms. Only public registry identity
    # coordinates (including the signing public key) enter the context, never
    # auth keys, passwords, query strings, or request headers. Also consider the
    # XDG config directory, which may differ from the cache/data directory.
    xdg = System.get_env("XDG_CONFIG_HOME", Path.join(System.user_home!(), ".config"))
    configs = [Path.join(home, "hex.config"), Path.join([xdg, "hex", "hex.config"])]
    registries = Enum.map(Enum.uniq(configs), &registry_identity!/1)

    digest(
      :erlang.term_to_binary({
        home,
        System.get_env("MIX_XDG"),
        System.get_env("XDG_CONFIG_HOME"),
        System.get_env("XDG_DATA_HOME"),
        mirrors,
        registries,
        Enum.map(@trust_env, &System.get_env/1)
      })
    )
  end

  defp safe_url(nil), do: nil
  defp safe_url(url) when is_list(url), do: safe_url(to_string(url))

  defp safe_url(url) when is_binary(url) do
    %URI{scheme: scheme, host: host, port: port, path: path} = URI.parse(url)
    {scheme, host, port, path}
  end

  defp registry_identity!(path) do
    case :file.consult(String.to_charlist(path)) do
      {:error, :enoent} -> {path, :missing}
      {:ok, terms} -> {path, registry_coordinates(terms)}
      {:error, _reason} -> Mix.raise("Cannot read Hex registry configuration at #{path}")
    end
  end

  defp registry_coordinates(value) when is_map(value),
    do: registry_coordinates(Map.to_list(value))

  defp registry_coordinates(value) when is_list(value) do
    value
    |> Enum.flat_map(fn
      {key, url}
      when key in [
             :url,
             :mirror_url,
             :trusted_mirror_url,
             "url",
             "mirror_url",
             "trusted_mirror_url"
           ] and (is_binary(url) or is_list(url)) ->
        [{to_string(key), safe_url(url)}]

      {key, public_key} when key in [:public_key, "public_key"] ->
        [{"public_key", digest(:erlang.term_to_binary(public_key))}]

      {key, nested} when is_map(nested) or is_list(nested) ->
        if is_atom(key) or is_binary(key) do
          coordinates = registry_coordinates(nested)
          if coordinates == [], do: [], else: [{to_string(key), coordinates}]
        else
          []
        end

      nested when is_map(nested) or is_list(nested) ->
        registry_coordinates(nested)

      _ ->
        []
    end)
    |> Enum.sort()
  end

  defp registry_coordinates(_), do: []

  # Static checks consider the project declaration, not unrelated keyword
  # entries in application/dependency functions. Dynamic metadata is resolved
  # by normal Mix dependency loading and checked by the consumer gate.
  defp check_identity!(app, path, requirement) do
    mix = Path.join(path, "mix.exs")
    unless File.regular?(mix), do: Mix.raise("Missing Mix project: #{path}")

    ast =
      case Code.string_to_quoted(File.read!(mix)) do
        {:ok, tree} -> tree
        {:error, _} -> Mix.raise("Cannot parse selected project: #{mix}")
      end

    {_, declarations} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{:project, _, args}, [do: body]]} = node, acc when args in [nil, []] ->
          {node, [body | acc]}

        node, acc ->
          {node, acc}
      end)

    version_file = Path.join(path, "VERSION")

    unless File.regular?(version_file) and
             Version.match?(String.trim(File.read!(version_file)), requirement),
           do: Mix.raise("Selected project VERSION does not satisfy #{app} #{requirement}")

    if app == :med_ex do
      contracts =
        Enum.flat_map(["lib", "core/*/lib", "components/core/*/lib"], fn lib ->
          Path.wildcard(Path.join([path, lib, "med_ex/contract.ex"]))
        end)

      unless Enum.any?(
               contracts,
               &(File.read!(&1) =~ ~r/def\s+api_revision(?:\(\))?,\s*do:\s*2\b/)
             ),
             do: Mix.raise("Selected med_ex project must declare API revision 2")
    end

    for body <- declarations do
      metadata = literal_project_metadata(body)
      apps = Keyword.get_values(metadata, :app) |> Enum.uniq()
      if apps != [] and apps != [app], do: Mix.raise("Selected project does not declare #{app}")

      for version <- Keyword.get_values(metadata, :version), is_binary(requirement) do
        case Version.parse(version) do
          {:ok, parsed} ->
            unless Version.match?(parsed, requirement),
              do:
                Mix.raise(
                  "Selected project version #{version} does not satisfy #{app} #{requirement}"
                )

          :error ->
            Mix.raise("Invalid selected project version for #{app}")
        end
      end
    end
  end

  # Direct keyword result, the final expression of a block, or a concatenated
  # declaration such as [app: ..., version: ...] ++ paths. More dynamic forms
  # are left to actual Mix loading rather than misidentifying nested options.
  defp literal_project_metadata({:__block__, _, expressions}),
    do: literal_project_metadata(List.last(expressions))

  defp literal_project_metadata({:++, _, [left, right]}),
    do: literal_project_metadata(left) ++ literal_project_metadata(right)

  defp literal_project_metadata(list) when is_list(list) do
    Enum.filter(list, fn
      {:app, value} -> is_atom(value)
      {:version, value} -> is_binary(value)
      _ -> false
    end)
  end

  defp literal_project_metadata(_), do: []

  defp split({app, requirement, options}), do: {app, requirement, options}
  defp split({app, requirement}) when is_binary(requirement), do: {app, requirement, []}
  defp split({app, options}) when is_list(options), do: {app, nil, options}

  defp source!(%{"path" => path} = data, base) when map_size(data) == 1 and is_binary(path) do
    unless coordinate?(path), do: Mix.raise("Invalid Mix source path")
    [path: Path.expand(path, base)]
  end

  defp source!(%{"hex" => package} = data, _base) when is_binary(package) do
    keys!(data, ~w(hex repo))
    repo = Map.get(data, "repo", "hexpm")

    unless Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, package) and coordinate?(repo) and
             Regex.match?(~r/\A[a-zA-Z0-9_:-]+\z/, repo) do
      Mix.raise("Invalid Hex package or repository")
    end

    [hex: package, repo: repo]
  end

  defp source!(data, base) when is_map(data) do
    keys!(data, Enum.map(@git_keys, &Atom.to_string/1))
    origins = Enum.filter(~w(github git), &Map.has_key?(data, &1))
    ref = data["ref"]

    unless length(origins) == 1 and is_binary(ref) and
             Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, ref) and
             Enum.all?(Map.values(data), &coordinate?/1) do
      Mix.raise("Select one Git origin and an exact 40-character commit SHA")
    end

    data = Map.put(data, "ref", String.downcase(ref))

    if github = data["github"] do
      unless Regex.match?(~r/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/, github),
        do: Mix.raise("GitHub selection requires owner/repository")
    end

    if subdir = data["subdir"] do
      if Path.type(subdir) != :relative or String.contains?(subdir, "\\") or
           Enum.any?(String.split(subdir, "/"), &(&1 in ["", ".", ".."])),
         do: Mix.raise("Git subdir must stay inside the checkout")
    end

    for key <- @git_keys, Map.has_key?(data, Atom.to_string(key)) do
      value = Map.fetch!(data, Atom.to_string(key))
      {key, if(key == :git, do: git_location(value, base), else: value)}
    end
  end

  defp source!(_, _), do: Mix.raise("A source selection must be an object")

  defp coordinate?(value) do
    is_binary(value) and value != "" and String.trim(value) == value and
      not String.contains?(value, [<<0>>, "\n", "\r"])
  end

  defp git_location(value, base) do
    if Regex.match?(~r/\A[^\/]+:/, value), do: value, else: Path.expand(value, base)
  end

  defp keys!(data, keys) do
    unless Enum.all?(Map.keys(data), &(&1 in keys)),
      do: Mix.raise("Unknown/conflicting source option")
  end

  defp dependency_inputs(path) do
    # Mix handles ordinary source and asset edits incrementally. A dependency
    # project, lock or composition edit may change the entire resolved graph.
    paths =
      (~w(mix.exs mix.lock VERSION build_support/composition.exs) ++
         Path.wildcard(Path.join(path, "core/*/{mix.exs,mix.lock}")))
      |> Enum.map(&Path.expand(&1, path))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(paths, &{Path.relative_to(&1, path), optional_digest(&1)})
  end

  defp artifact_identity(path) do
    marker = Path.join(path, "weld.provenance.json")

    if File.regular?(marker) do
      case read_object!(File.read!(marker), marker) do
        %{"kind" => "full", "artifact_id" => id} when is_binary(id) and id != "" ->
          lock = Path.join(path, "projection.lock.json")

          files =
            case read_object!(File.read!(lock), lock) do
              %{"projection" => %{"verification_files" => files}} when is_list(files) -> files
              _ -> Mix.raise("Invalid frozen projection inventory at #{lock}")
            end

          # Freeze actual inputs, including additions to compiler/asset inputs
          # that are absent from a stale marker. Avoid docs and Mix build output
          # outside the advertised inventory.
          extra =
            Enum.flat_map(
              ~w(lib src priv components config build_support Makefile c_src),
              &frozen_files(path, &1)
            )

          inventory =
            (files ++ extra ++ ~w(weld.provenance.json projection.lock.json mix.exs))
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.map(&frozen_input!(path, &1))

          {id, digest(:erlang.term_to_binary(inventory))}

        %{"kind" => "live"} ->
          nil

        _ ->
          Mix.raise("Invalid projection identity at #{marker}")
      end
    end
  end

  defp frozen_files(root, relative) do
    path = Path.join(root, relative)

    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        path
        |> File.ls!()
        |> Enum.reject(&(&1 in ["_build", "deps", "tmp"]))
        |> Enum.flat_map(&frozen_files(root, Path.join(relative, &1)))

      {:error, :enoent} ->
        []

      _ ->
        [relative]
    end
  end

  defp frozen_input!(root, relative) do
    invalid = fn -> Mix.raise("Invalid frozen projection input at #{root}") end
    unless is_binary(relative) and Path.type(relative) == :relative, do: invalid.()
    segments = String.split(relative, "/")
    if Enum.any?(segments, &(&1 in ["", ".", ".."])), do: invalid.()

    path =
      Enum.reduce(segments, root, fn segment, parent ->
        child = Path.join(parent, segment)

        case File.lstat(child) do
          {:ok, %{type: type}} when type in [:directory, :regular] -> child
          _ -> invalid.()
        end
      end)

    case File.lstat!(path) do
      %{type: :regular, mode: mode} ->
        {relative, Bitwise.band(mode, 0o111), digest(File.read!(path))}

      _ ->
        invalid.()
    end
  end

  defp optional_digest(path) do
    case File.read(path) do
      {:ok, bytes} -> digest(bytes)
      {:error, :enoent} -> nil
      {:error, reason} -> Mix.raise("Cannot read build input #{path}: #{reason}")
    end
  end

  defp read_object!(bytes, file) do
    decoders = [
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        if Map.has_key?(acc, key), do: Mix.raise("Duplicate JSON key in #{file}")
        Map.put(acc, key, value)
      end,
      object_finish: fn acc, parent -> {acc, parent} end
    ]

    case JSON.decode(bytes, nil, decoders) do
      {value, nil, rest} when is_map(value) ->
        if String.trim(rest) != "", do: Mix.raise("Trailing JSON in #{file}")
        value

      _ ->
        Mix.raise("Expected a JSON object in #{file}")
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
