defmodule MedFabric.BuildSources do
  @moduledoc false
  @repo_apps ~w(med_ex med_ex_opus med_ex_rtc mf_domain mf_store mf_interop)
  @scm ~w(path in_umbrella git github ref branch tag subdir sparse submodules depth hex repo organization)a

  # This is committed repository-owned code, never loaded from a user-provided executable path.
  # Call once in project/0 and use both return values. Runtime apps do not call this module.
  def resolve(defaults, project_dir, repo_root) do
    file = Path.join(repo_root, ".mix_sources.json")
    overrides = if File.exists?(file), do: read_object!(file), else: %{}

    known =
      Map.new(defaults, fn dep ->
        {app, _, _} = split(dep)
        {Atom.to_string(app), app}
      end)

    allowed = MapSet.new(@repo_apps ++ Map.keys(known))

    unless Enum.all?(Map.keys(overrides), &MapSet.member?(allowed, &1)),
      do: Mix.raise("Unknown dependency in #{file}")

    # The previous single-candidate flag is translated at the build boundary.
    old = System.get_env("MF_MED_EX_PATH")
    if old && map_size(overrides) > 0, do: Mix.raise("Choose .mix_sources.json or MF_MED_EX_PATH")
    overrides = if old, do: %{"med_ex" => %{"path" => old}}, else: overrides

    normalized =
      Enum.map(defaults, fn dep ->
        {app, requirement, policy} = split(dep)

        case Map.fetch(overrides, Atom.to_string(app)) do
          :error ->
            dep

          {:ok, choice} ->
            source = source!(choice, Path.dirname(file))
            if path = source[:path], do: check_identity!(app, path)

            if Keyword.has_key?(source, :hex) and not is_binary(requirement),
              do: Mix.raise("Hex selection requires a committed version requirement")

            options = Keyword.drop(policy, @scm) ++ source
            if requirement, do: {app, requirement, options}, else: {app, options}
        end
      end)

    if map_size(overrides) == 0 do
      {normalized, []}
    else
      for name <- ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE),
          System.get_env(name) do
        Mix.raise(
          "#{name} conflicts with selected source isolation; unset it for this invocation"
        )
      end

      frozen = for dep <- normalized, identity = artifact_identity(dep), do: identity

      lock =
        case File.read(Path.join(project_dir, "mix.lock")) do
          {:ok, b} -> b
          _ -> ""
        end

      identity =
        {1, Path.expand(project_dir), normalized, frozen, digest(lock), System.version(),
         :erlang.system_info(:otp_release), :erlang.system_info(:system_architecture), Mix.env(),
         Mix.target()}

      context = digest(:erlang.term_to_binary(identity))
      root = Path.join([Path.expand(project_dir), "_build", "source_contexts", context])

      {normalized,
       [
         lockfile: Path.join(root, "mix.lock"),
         deps_path: Path.join(root, "deps"),
         build_path: Path.join(root, "build")
       ]}
    end
  end

  # Inspect only literal app declarations. Mix performs final dependency identity
  # validation for projects with dynamically computed configuration.
  defp check_identity!(app, path) do
    ast = File.read!(Path.join(path, "mix.exs")) |> Code.string_to_quoted!()

    {_, apps} =
      Macro.prewalk(ast, [], fn
        {:app, name} = node, acc when is_atom(name) -> {node, [name | acc]}
        node, acc -> {node, acc}
      end)

    if apps != [] and app not in apps, do: Mix.raise("Selected project does not declare #{app}")
  end

  defp split({app, requirement, options}), do: {app, requirement, options}
  defp split({app, requirement}) when is_binary(requirement), do: {app, requirement, []}
  defp split({app, options}) when is_list(options), do: {app, nil, options}

  defp source!(%{"path" => path} = data, base) when map_size(data) == 1 and is_binary(path) do
    expanded = Path.expand(path, base)

    unless File.regular?(Path.join(expanded, "mix.exs")),
      do: Mix.raise("Missing Mix project: #{expanded}")

    [path: expanded]
  end

  defp source!(%{"hex" => package} = data, _base) when is_binary(package) do
    keys!(data, ~w(hex repo))
    repo = Map.get(data, "repo", "hexpm")
    unless is_binary(repo) and repo != "", do: Mix.raise("Invalid Hex repository")
    [hex: package, repo: repo]
  end

  defp source!(data, _base) when is_map(data) do
    keys!(data, ~w(github git ref branch tag subdir))
    origins = Enum.filter(~w(github git), &Map.has_key?(data, &1))
    refs = Enum.filter(~w(ref branch tag), &Map.has_key?(data, &1))

    unless length(origins) == 1 and length(refs) == 1 and
             Enum.all?(Map.values(data), &(is_binary(&1) and &1 != "")),
           do: Mix.raise("Select one Git origin and one ref, tag or branch")

    if subdir = data["subdir"] do
      if Path.type(subdir) != :relative or ".." in Path.split(subdir),
        do: Mix.raise("Git subdir must stay inside the checkout")
    end

    # Only this fixed whitelist can become atoms; input values never can.
    for key <- ~w(github git ref branch tag subdir),
        Map.has_key?(data, key),
        do: {String.to_existing_atom(key), Map.fetch!(data, key)}
  end

  defp source!(_, _), do: Mix.raise("A source selection must be an object")

  defp keys!(data, keys) do
    unless Enum.all?(Map.keys(data), &(&1 in keys)),
      do: Mix.raise("Unknown/conflicting source option")
  end

  defp artifact_identity(dep) do
    {app, _, options} = split(dep)

    if path = options[:path] do
      marker = Path.join(path, "weld.provenance.json")

      if File.regular?(marker) do
        case read_object!(marker) do
          %{"kind" => "full", "artifact_id" => id} when is_binary(id) -> {app, id}
          %{"kind" => "live"} -> nil
          _ -> Mix.raise("Invalid projection identity at #{marker}")
        end
      end
    end
  end

  defp read_object!(file) do
    decoders = [
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        if Map.has_key?(acc, key), do: Mix.raise("Duplicate JSON key in #{file}")
        Map.put(acc, key, value)
      end,
      object_finish: fn acc, parent -> {acc, parent} end
    ]

    case JSON.decode(File.read!(file), nil, decoders) do
      {value, nil, rest} when is_map(value) ->
        if String.trim(rest) != "", do: Mix.raise("Trailing JSON in #{file}")
        value

      _ ->
        Mix.raise("Expected a JSON object in #{file}")
    end
  end

  defp digest(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
end
