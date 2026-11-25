defmodule MedFabric.Domain.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()
  @source_url "https://github.com/nshkrdotcom/med_fabric"

  def project do
    [
      app: :mf_domain,
      version: @version,
      elixir: "~> 1.20",
      name: "Med Fabric Domain",
      description:
        "Pure Elixir clinical evidence constructors and encounter rules for Med Fabric",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer"]],
      deps: [
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
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
      logo: "assets/domain.svg",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "mf_domain-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/mf_domain-v#{@version}/core/domain/%{path}#L%{line}",
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
