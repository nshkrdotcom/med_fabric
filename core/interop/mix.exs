defmodule MedFabric.Interop.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_interop,
      version: __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim(),
      elixir: "~> 1.20",
      description: "Healthcare record exchange",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      deps: [
        {:req, "~> 0.7.5"},
        {:decimal, "~> 3.2"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
