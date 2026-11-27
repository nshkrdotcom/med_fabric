defmodule FabricHexSmoke.MixProject do
  use Mix.Project

  def project do
    [
      app: :fabric_hex_smoke,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [
        {:med_ex, "0.4.0"},
        {:med_ex_opus, "0.3.0"},
        {:med_ex_rtc, "0.3.0"},
        {:mf_exam, "0.3.0"},
        {:mf_handheld, "0.3.0"},
        {:mf_preview, "0.3.0"}
      ]
    ]
  end
end
