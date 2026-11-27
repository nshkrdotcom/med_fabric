defmodule MedFabric.ClinicalCoreFixture.MixProject do
  use Mix.Project

  def project do
    [
      app: :clinical_core_fixture,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [
        {:mf_domain, path: "../../core/domain"},
        {:mf_store, path: "../../core/store"},
        {:mf_interop, path: "../../core/interop"}
      ]
    ]
  end
end
