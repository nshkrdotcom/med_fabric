Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedFabric.Exam.MixProject do
  use Mix.Project

  def project do
    legacy_media? = System.get_env("MF_EXAM_LEGACY_MEDIA") == "1"

    {deps, paths} =
      MedFabric.BuildSources.resolve(deps(legacy_media?), __DIR__, Path.expand("../..", __DIR__))

    # Selected sources already get a build path keyed by their active dependencies.
    paths =
      if legacy_media? and paths == [] do
        [build_path: "_build/legacy_media"]
      else
        paths
      end

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

  defp deps(legacy_media?) do
    [
      {:mf_domain, path: "../../core/domain"},
      {:mf_store, path: "../../core/store"},
      {:mf_interop, path: "../../core/interop"},
      {:med_ex, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "c031a38a9e28fe6bccf1358d8f41fa419aa708d2",
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
      if(legacy_media?,
        do: [
          # Membrane needs Ratio compatible with the server's Decimal 3.
          {:ratio,
           git: "https://github.com/robertbenavidez/elixir-rational.git",
           ref: "05191dbe8061b49a170352f3c35c21360bdbb328",
           override: true},
          {:med_ex_opus, "~> 0.2.0",
           github: "nshkrdotcom/med_ex",
           ref: "3dbb770550ac1a4340eecb6951d5bf21c6f0fcb8",
           subdir: "extensions/med_ex_opus"},
          {:med_ex_rtc, "~> 0.2.0",
           github: "nshkrdotcom/med_ex",
           ref: "3dbb770550ac1a4340eecb6951d5bf21c6f0fcb8",
           subdir: "extensions/med_ex_rtc"}
        ],
        else: []
      )
  end
end
