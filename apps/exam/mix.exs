Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedFabric.Exam.MixProject do
  use Mix.Project

  def project do
    {deps, paths} = MedFabric.BuildSources.resolve(deps(), __DIR__, Path.expand("../..", __DIR__))

    [
      app: :mf_exam,
      version: __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim(),
      elixir: "~> 1.20",
      description: "Connected remote clinical examination",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      deps: deps
    ] ++ paths
  end

  def application do
    [mod: {MedFabric.Exam.Application, []}]
  end

  defp deps do
    [
      {:mf_domain, path: "../../core/domain"},
      {:mf_store, path: "../../core/store"},
      {:mf_interop, path: "../../core/interop"},
      {:med_ex, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "83defa6d16e5062b3b027cb0e1dbec98bac38705",
       override: true},
      # Ratio PR 131 widens its optional Decimal constraint. Keep this pin in the
      # deployable application until Hex ships that change.
      {:ratio,
       git: "https://github.com/robertbenavidez/elixir-rational.git",
       ref: "05191dbe8061b49a170352f3c35c21360bdbb328",
       override: true},
      {:decimal, "~> 3.2"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ] ++
      if(System.get_env("MF_EXAM_LEGACY_MEDIA") == "1",
        do: [
          {:med_ex_opus, "~> 0.2.0",
           github: "nshkrdotcom/med_ex",
           ref: "6e69605f256925ea2f7e03a377fca9ad5bc6bce0",
           subdir: "extensions/med_ex_opus"},
          {:med_ex_rtc, "~> 0.2.0",
           github: "nshkrdotcom/med_ex",
           ref: "6e69605f256925ea2f7e03a377fca9ad5bc6bce0",
           subdir: "extensions/med_ex_rtc"}
        ],
        else: []
      )
  end
end
