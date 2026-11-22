if bootstrap = System.get_env("MIX_WORKSPACE_OPS_BOOTSTRAP"), do: Code.require_file(bootstrap)

defmodule MedFabric.Rtc.MixProject do
  use Mix.Project

  @med_ex_ref "c26b481d6b8115e3522c8c65d59203ba2dce68f5"

  def project do
    [
      app: :mf_rtc,
      version: "0.1.0",
      elixir: "~> 1.18",
      description: "Encounter-to-MedEx live session bridge",
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer"]],
      deps: deps()
    ]
  end

  defp deps do
    [
      {:mf_domain, path: "../domain"},
      workspace_dep(
        {:med_core,
         github: "nshkrdotcom/med_ex",
         ref: @med_ex_ref,
         subdir: "core/med_core",
         override: true}
      ),
      workspace_dep(
        {:med_rtc, github: "nshkrdotcom/med_ex", ref: @med_ex_ref, subdir: "core/med_rtc"}
      ),
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
