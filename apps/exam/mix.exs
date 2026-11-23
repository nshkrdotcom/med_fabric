defmodule MedFabric.Exam.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_exam,
      version: __DIR__ |> Path.join("../../VERSION") |> File.read!() |> String.trim(),
      elixir: "~> 1.20",
      description: "Connected remote clinical examination",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      lockfile: if(candidate_path(), do: "_build/candidate.mix.lock", else: "mix.lock"),
      deps: deps()
    ]
  end

  def application do
    [mod: {MedFabric.Exam.Application, []}]
  end

  defp deps do
    [
      {:mf_domain, path: "../../core/domain"},
      {:mf_store, path: "../../core/store"},
      {:mf_interop, path: "../../core/interop"},
      med_ex_dep(),
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
    ]
  end

  defp med_ex_dep do
    case candidate_path() do
      nil -> {:med_ex, "~> 0.2.0"}
      path -> {:med_ex, path: path}
    end
  end

  defp candidate_path, do: System.get_env("MF_MED_EX_PATH")
end
