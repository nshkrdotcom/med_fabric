Code.require_file("../../config/sources.exs", __DIR__)

defmodule MedFabric.Preview.MixProject do
  use Mix.Project

  def project do
    defaults = [
      {:med_ex, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "83defa6d16e5062b3b027cb0e1dbec98bac38705",
       override: true},
      {:med_ex_opus, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "6e69605f256925ea2f7e03a377fca9ad5bc6bce0",
       subdir: "extensions/med_ex_opus"},
      {:med_ex_rtc, "~> 0.2.0",
       github: "nshkrdotcom/med_ex",
       ref: "6e69605f256925ea2f7e03a377fca9ad5bc6bce0",
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
