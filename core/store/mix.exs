sources_path = Path.expand("../../config/sources.exs", __DIR__)
if File.regular?(sources_path), do: Code.require_file(sources_path)

defmodule MedFabric.Store.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()
  @source_url "https://github.com/nshkrdotcom/med_fabric"

  def project do
    defaults = [
      {:mf_domain, path: "../domain"},
      {:postgrex, "~> 0.23"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 3.2"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
    ]

    {deps, paths} =
      if Code.ensure_loaded?(MedFabric.BuildSources) do
        MedFabric.BuildSources.resolve(defaults, __DIR__, Path.expand("../..", __DIR__))
      else
        {defaults, []}
      end

    [
      app: :mf_store,
      version: @version,
      elixir: "~> 1.20",
      name: "Med Fabric Store",
      description: "Transactional PostgreSQL persistence and FHIR outbox storage for Med Fabric",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      deps: deps,
      docs: docs(),
      package: package()
    ] ++ paths
  end

  defp package do
    [
      files: ~w(.formatter.exs mix.exs VERSION LICENSE README.md CHANGELOG.md assets lib priv),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/store.svg",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "mf_store-v#{@version}",
      source_url_pattern: "#{@source_url}/blob/mf_store-v#{@version}/core/store/%{path}#L%{line}",
      extras: [
        {"README.md", filename: "readme", title: "Overview"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "License"}
      ],
      groups_for_extras: [
        Overview: ["README.md"],
        Release: ["CHANGELOG.md", "LICENSE"]
      ]
    ]
  end
end
