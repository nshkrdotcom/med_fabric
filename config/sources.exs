defmodule MedFabric.BuildSources do
  @moduledoc false

  @med_ex_apps [:med_ex, :med_ex_opus, :med_ex_rtc]
  @med_ex_requirement "~> 0.2.0"
  # Baseline provider revision. Repin this family after the verified MedEx push.
  @med_ex_revision "b30d517305f93b84c94664bb0f9767c9aad23c29"
  @repo_apps ~w(med_ex med_ex_opus med_ex_rtc mf_domain mf_store mf_interop)
  @git_keys [:github, :git, :ref, :subdir]
  @scm @git_keys ++ ~w(branch tag path in_umbrella sparse submodules depth hex repo organization)a
  @mix_paths ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE)

  def med_ex_dependency(app) when app in @med_ex_apps do
    git = [github: "nshkrdotcom/med_ex", ref: @med_ex_revision]
    options = if app == :med_ex, do: [override: true], else: [subdir: "extensions/#{app}"]
    {app, @med_ex_requirement, git ++ options}
  end

  # Loaded only by the repository-owned Mix projects.
  def resolve(defaults, project_dir, repo_root, options \\ []) do
    file = Path.join(repo_root, ".mix_sources.json")
    profile = Keyword.get(options, :profile, :default)
    declared = Enum.map(defaults, fn dep -> dep |> elem(0) |> Atom.to_string() end)
    choices = selections!(file)
    # Store is the only participating internal project with selectable deps.
    # Its domain selection also changes the dependency consumer's closure.
    effective_apps = if "mf_store" in declared, do: ["mf_domain" | declared], else: declared
    active = Map.take(choices, effective_apps)

    # Validate the effective Store -> Domain choice even in its outer consumer.
    if "mf_store" in declared and "mf_domain" not in declared and active["mf_domain"] do
      choice = active["mf_domain"]
      if path = choice[:path], do: check_identity!(:mf_domain, path, nil)

      if choice[:hex],
        do: Mix.raise("Hex selection requires a committed version requirement for mf_domain")
    end

    deps = Enum.map(defaults, &apply_choice!(&1, active))

    if active == %{} and profile == :default do
      {deps, []}
    else
      {deps, context_paths!(deps, active, Path.expand(project_dir), profile)}
    end
  end

  defp selections!(file) do
    input = File.read(file)
    legacy = System.get_env("MF_MED_EX_PATH")

    data =
      case {input, legacy} do
        {{:ok, _bytes}, path} when is_binary(path) ->
          Mix.raise("Choose .mix_sources.json or the deprecated MF_MED_EX_PATH")

        {{:ok, bytes}, nil} ->
          read_object!(bytes, file)

        {{:error, :enoent}, path} when is_binary(path) ->
          %{"med_ex" => %{"path" => path}}

        {{:error, :enoent}, nil} ->
          %{}

        {{:error, reason}, _} ->
          Mix.raise("Cannot read #{file}: #{inspect(reason)}")
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

  defp context_paths!(deps, active, project, profile) do
    for name <- @mix_paths, System.get_env(name) do
      Mix.raise("#{name} conflicts with source/profile isolation; unset it for this invocation")
    end

    normalized =
      Enum.map(deps, fn dep ->
        {app, requirement, options} = split(dep)
        {app, requirement, Enum.sort(options)}
      end)

    frozen =
      for {app, options} <- active, identity = artifact_identity(app, options), do: identity

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
    hex = hex_context()

    identity =
      {3, project, profile, normalized, Enum.sort(active), Enum.sort(frozen), hex, lock_digest,
       System.version(), otp_version, :erlang.system_info(:system_architecture), Mix.env(),
       Mix.target()}

    context = digest(:erlang.term_to_binary(identity))
    root = Path.join([project, "_build", "source_contexts", context])

    [
      lockfile: Path.join(root, "mix.lock"),
      deps_path: Path.join(root, "deps"),
      build_path: Path.join(root, "build")
    ]
  end

  defp hex_context do
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

    {home, System.get_env("MIX_XDG"), System.get_env("XDG_CONFIG_HOME"),
     System.get_env("XDG_DATA_HOME"), mirrors, registries}
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

  defp artifact_identity(app, options) do
    if path = options[:path] do
      marker = Path.join(path, "weld.provenance.json")

      if File.regular?(marker) do
        case read_object!(File.read!(marker), marker) do
          %{"kind" => "full", "artifact_id" => id} when is_binary(id) and id != "" -> {app, id}
          %{"kind" => "live"} -> nil
          _ -> Mix.raise("Invalid projection identity at #{marker}")
        end
      end
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
