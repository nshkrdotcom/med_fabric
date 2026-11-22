defmodule MedFabric.Store.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_store,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Clinical persistence and audit",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer"]],
      deps: [
        {:mf_domain, path: "../domain"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
