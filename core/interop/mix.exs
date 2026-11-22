defmodule MedFabric.Interop.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_interop,
      version: "0.1.0",
      elixir: "~> 1.20",
      description: "Healthcare record exchange",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      deps: [
        {:mf_domain, path: "../domain"},
        {:req, "~> 0.7.5"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
