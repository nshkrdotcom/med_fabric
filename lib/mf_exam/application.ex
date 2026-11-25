defmodule MfExam.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    bootstrap_workspace_app_env!()

    children = [
      %{
        id: {"apps/exam", MedFabric.Exam.Application},
        start: {MedFabric.Exam.Application, :start, [:normal, []]},
        type: :supervisor
      }
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end

  @boot_env Mix.env()
  @bootstrapped_apps [:mf_exam]
  @bootstrapped_sources [
    %{
      config_path: "config/runtime_sources/apps_exam/config.exs",
      env_path_fallbacks: %{
        dev: nil,
        prod: nil,
        test: "config/runtime_sources/apps_exam/test.exs"
      },
      runtime_path: "config/runtime_sources/apps_exam/runtime.exs"
    }
  ]

  defp bootstrap_workspace_app_env! do
    Enum.each(@bootstrapped_sources, fn source ->
      source
      |> bootstrap_source_paths()
      |> Enum.each(&apply_bootstrap_source!/1)
    end)
  end

  defp bootstrap_source_paths(%{
         config_path: config_path,
         env_path_fallbacks: env_path_fallbacks,
         runtime_path: runtime_path
       }) do
    []
    |> maybe_add_bootstrap_path(config_path || Map.get(env_path_fallbacks, @boot_env))
    |> maybe_add_bootstrap_path(runtime_path)
  end

  defp maybe_add_bootstrap_path(paths, nil), do: paths
  defp maybe_add_bootstrap_path(paths, path), do: paths ++ [path]

  defp apply_bootstrap_source!(relative_path) do
    absolute_path = artifact_path(relative_path)

    unless File.regular?(absolute_path) do
      raise "missing projected workspace config source: #{absolute_path}"
    end

    {config, _imports} = Config.Reader.read_imports!(absolute_path, env: @boot_env)

    config
    |> Enum.filter(fn {app, _value} -> app in @bootstrapped_apps end)
    |> case do
      [] -> :ok
      workspace_config -> Application.put_all_env(workspace_config, persistent: true)
    end
  end

  defp artifact_path(relative_path) do
    Path.expand(Path.join(["..", "..", relative_path]), __DIR__)
  end
end
