Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedFabric.Store.MixProject do
  use Mix.Project

  def project do
    defaults = [
        {:mf_domain, path: "../domain"},
        {:postgrex, "~> 0.23"},
        {:jason, "~> 1.4"},
        {:decimal, "~> 3.2"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
    {deps, paths} = MedFabric.BuildSources.resolve(defaults, __DIR__, Path.expand("../..", __DIR__))
    [
      app: :mf_store,
      version: __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim(),
      elixir: "~> 1.20",
      description: "Clinical persistence and audit",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      deps: deps
    ] ++ paths
  end
end
