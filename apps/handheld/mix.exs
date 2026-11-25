sources_path = Path.expand("../../config/sources.exs", __DIR__)
if File.regular?(sources_path), do: Code.require_file(sources_path)

defmodule MedExHandheld.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()
  @source_url "https://github.com/nshkrdotcom/med_fabric"

  def project do
    {deps, paths} = resolve_deps()

    [
      app: :mf_handheld,
      version: @version,
      elixir: "~> 1.20",
      name: "Med Fabric Handheld",
      description:
        "Standalone synthetic medical peripheral client with TLS transport and bounded disk spool",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["format --check-formatted", "compile --warnings-as-errors"]],
      deps: deps,
      docs: docs(),
      package: package()
    ] ++ paths
  end

  def application do
    [
      mod: {MedExHandheld.Application, []},
      extra_applications: [:crypto, :ssl, :public_key]
    ]
  end

  defp resolve_deps do
    dev_deps = [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
    ]

    if Code.ensure_loaded?(MedFabric.BuildSources) and
         (File.regular?(Path.expand("../../.mix_sources.json", __DIR__)) or
            is_binary(System.get_env("MF_MED_EX_PATH"))) do
      MedFabric.BuildSources.resolve(
        [
          MedFabric.BuildSources.med_ex_dependency(:med_ex),
          {:gun, "~> 2.8.0"}
        ] ++ dev_deps,
        __DIR__,
        Path.expand("../..", __DIR__)
      )
    else
      {[
         {:med_ex, "~> 0.2.1", hex: "med_ex", repo: "hexpm"},
         {:gun, "~> 2.8.0"}
       ] ++ dev_deps, []}
    end
  end

  defp package do
    [
      files: ~w(.formatter.exs mix.exs VERSION LICENSE README.md CHANGELOG.md assets guides lib),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "MedEx" => "https://hex.pm/packages/med_ex"
      }
    ]
  end

  defp docs do
    guides = [
      {"guides/getting_started.md", title: "Getting Started"},
      {"guides/spool_and_recovery.md", title: "Spool & Recovery"},
      {"guides/deployment.md", title: "Deployment"}
    ]

    [
      main: "readme",
      logo: "assets/handheld.svg",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "mf_handheld-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/mf_handheld-v#{@version}/apps/handheld/%{path}#L%{line}",
      extras:
        [
          {"README.md", filename: "readme", title: "Overview"}
        ] ++
          guides ++
          [
            {"CHANGELOG.md", title: "Changelog"},
            {"LICENSE", title: "License"}
          ],
      groups_for_extras: [
        Overview: ["README.md"],
        Guides: Enum.map(guides, &elem(&1, 0)),
        Release: ["CHANGELOG.md", "LICENSE"]
      ],
      groups_for_modules: [
        "Session & CLI": [
          MedExHandheld.Application,
          MedExHandheld.Session,
          MedExHandheld.Paired,
          MedExHandheld.CLI
        ],
        Peripherals: [
          MedExHandheld.SourceAdapter,
          MedExHandheld.RDP1,
          MedExHandheld.ReferencePeripheral,
          MedExHandheld.PLXAdapter,
          MedExHandheld.PLXPeripheral
        ],
        "Spool & Transport": [
          MedExHandheld.Spool,
          MedExHandheld.Transport,
          MedExHandheld.Monitor
        ]
      ]
    ]
  end
end
