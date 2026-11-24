Code.require_file("../../config/sources.exs", __DIR__)
defmodule MedExHandheld.MixProject do
  use Mix.Project
  def project do
    {deps,paths}=MedFabric.BuildSources.resolve([{:med_ex,"~> 0.2.0",github: "nshkrdotcom/med_ex",branch: "main",override: true},{:gun,"== 2.2.0"}],__DIR__,Path.expand("../..",__DIR__))
    [app: :mf_handheld,version: File.read!(Path.expand("../../VERSION",__DIR__)) |> String.trim(),elixir: "~> 1.20",deps: deps] ++ paths
  end
  def application,do: [mod: {MedExHandheld.Application,[]},extra_applications: [:crypto,:ssl,:public_key]]
end
