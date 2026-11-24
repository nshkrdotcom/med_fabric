Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedFabric.Preview.MixProject do
  use Mix.Project
  alias MedFabric.BuildSources

  def project do
    defaults = [
      BuildSources.med_ex_dependency(:med_ex),
      BuildSources.med_ex_dependency(:med_ex_opus),
      BuildSources.med_ex_dependency(:med_ex_rtc),
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"}
    ]

    {deps, paths} =
      BuildSources.resolve(defaults, __DIR__, Path.expand("../..", __DIR__))

    [
      app: :mf_preview,
      version: File.read!(Path.expand("../../VERSION", __DIR__)) |> String.trim(),
      elixir: "~> 1.20",
      aliases: [quality: ["format --check-formatted", "compile --warnings-as-errors"]],
      deps: deps
    ] ++ paths
  end

  def application, do: [mod: {MedFabric.Preview.Application, []}, extra_applications: [:crypto]]
end
