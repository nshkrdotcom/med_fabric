Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedFabric.Preview.MixProject do
  use Mix.Project

  def project do
    defaults = [
      {:med_ex, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "c031a38a9e28fe6bccf1358d8f41fa419aa708d2",
       override: true},
      {:med_ex_opus, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "3dbb770550ac1a4340eecb6951d5bf21c6f0fcb8",
       subdir: "extensions/med_ex_opus"},
      {:med_ex_rtc, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "3dbb770550ac1a4340eecb6951d5bf21c6f0fcb8",
       subdir: "extensions/med_ex_rtc"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"}
    ]

    {deps, paths} =
      MedFabric.BuildSources.resolve(defaults, __DIR__, Path.expand("../..", __DIR__))

    [
      app: :mf_preview,
      version: File.read!(Path.expand("../../VERSION", __DIR__)) |> String.trim(),
      elixir: "~> 1.20",
      deps: deps
    ] ++ paths
  end

  def application, do: [mod: {MedFabric.Preview.Application, []}, extra_applications: [:crypto]]
end
