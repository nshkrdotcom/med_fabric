defmodule MedFabric.Media.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_media,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Clinical artifact provenance and recorded signal review indexing",
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
