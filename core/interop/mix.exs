defmodule MedFabric.Interop.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()
  @release_version "0.3.0"
  @source_url "https://github.com/nshkrdotcom/med_fabric"

  def project do
    [
      app: :mf_interop,
      version: @version,
      elixir: "~> 1.20",
      name: "Med Fabric Interop",
      description: "HL7 FHIR R4 Observation mapping and idempotent delivery for Med Fabric",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [
        quality: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "cmd env MIX_ENV=test mix test --warnings-as-errors",
          "credo --strict",
          "dialyzer",
          "docs --warnings-as-errors"
        ]
      ],
      deps: [
        {:req, "~> 0.7.5"},
        {:decimal, "~> 3.2.0"},
        {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4.9", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
      ],
      docs: docs(),
      package: package()
    ]
  end

  defp package do
    [
      files: ~w(.formatter.exs mix.exs VERSION LICENSE README.md CHANGELOG.md assets lib),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/interop.svg",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "mf_exam-v#{@release_version}",
      source_url_pattern:
        "#{@source_url}/blob/mf_exam-v#{@release_version}/core/interop/%{path}#L%{line}",
      extras: [
        {"README.md", filename: "readme", title: "Overview"},
        {"CHANGELOG.md", title: "Changelog"},
        {"LICENSE", title: "License"}
      ],
      groups_for_extras: [
        Overview: ["README.md"],
        Release: ["CHANGELOG.md", "LICENSE"]
      ]
    ]
  end
end
