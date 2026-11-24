Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedExHandheld.MixProject do
  use Mix.Project
  alias MedFabric.BuildSources

  def project do
    {deps, paths} =
      BuildSources.resolve(
        [
          BuildSources.med_ex_dependency(:med_ex),
          {:gun, "~> 2.8.0"}
        ],
        __DIR__,
        Path.expand("../..", __DIR__)
      )

    [
      app: :mf_handheld,
      version: File.read!(Path.expand("../../VERSION", __DIR__)) |> String.trim(),
      elixir: "~> 1.20",
      aliases: [quality: ["format --check-formatted", "compile --warnings-as-errors"]],
      deps: deps
    ] ++ paths
  end

  def application,
    do: [mod: {MedExHandheld.Application, []}, extra_applications: [:crypto, :ssl, :public_key]]
end
