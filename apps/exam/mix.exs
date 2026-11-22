if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule MedFabric.Exam.MixProject do
  use Mix.Project

  @med_ex_projection_ref "3ac1df64601024cd6e1361364d4a29957a1f33ff"

  def project do
    [
      app: :mf_exam,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Connected remote clinical examination",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer"]],
      deps: deps()
    ]
  end

  defp deps do
    [
      {:mf_runtime, path: "../../core/runtime"},
      {:mf_store, path: "../../core/store"},
      {:mf_interop, path: "../../core/interop"},
      workspace_dep({:med_ex, github: "nshkrdotcom/med_ex", ref: @med_ex_projection_ref}),
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
