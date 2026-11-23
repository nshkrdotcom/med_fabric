if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule MedFabric.Exam.MixProject do
  use Mix.Project

  @med_ex_projection_ref "8487c3306d02dc2a7bb68ffa4dea9ef1f172a7f6"

  def project do
    [
      app: :mf_exam,
      version: "0.1.0",
      elixir: "~> 1.20",
      description: "Connected remote clinical examination",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
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
      workspace_dep({:med_ex, github: "nshkrdotcom/med_ex", ref: @med_ex_projection_ref}),
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp workspace_dep(committed) do
    if function_exported?(MixWorkspaceOpsBootstrap, :dep, 2),
      do: apply(MixWorkspaceOpsBootstrap, :dep, [committed, __DIR__]),
      else: committed
  end
end
