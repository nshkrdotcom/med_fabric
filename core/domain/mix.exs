defmodule MedFabric.Domain.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_domain,
      version: __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim(),
      elixir: "~> 1.20",
      description: "Pure encounter decisions",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer"]],
      deps: [
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
