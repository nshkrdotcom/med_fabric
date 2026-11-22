defmodule MedFabric.Steth.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_steth,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Remote digital stethoscope",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer"]],
      deps: [
        {:mf_runtime, path: "../../core/runtime"},
        {:mf_store, path: "../../core/store"},
        {:mf_devices, path: "../../core/devices"},
        {:mf_rtc, path: "../../core/rtc"},
        {:mf_media, path: "../../core/media"},
        {:mf_web, path: "../../core/web"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ]
    ]
  end
end
