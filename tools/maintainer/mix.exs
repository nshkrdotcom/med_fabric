defmodule MedFabric.Maintainer.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_fabric_maintainer,
      version: "0.0.0",
      elixir: "~> 1.20",
      deps: [{:weld, "~> 0.20.3", runtime: false}]
    ]
  end
end
