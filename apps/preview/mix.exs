sources_path = Path.expand("../../config/sources.exs", __DIR__)
if File.regular?(sources_path), do: Code.require_file(sources_path)

defmodule MedFabric.Preview.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()
  @source_url "https://github.com/nshkrdotcom/med_fabric"

  def project do
    {deps, paths} = resolve_deps()

    [
      app: :mf_preview,
      version: @version,
      elixir: "~> 1.20",
      name: "Med Fabric Preview",
      description:
        "Isolated live acoustic monitor service for Med Fabric using MedEx Opus and WebRTC providers",
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
      mod: {MedFabric.Preview.Application, []},
      extra_applications: [:crypto]
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
      defaults =
        [
          MedFabric.BuildSources.med_ex_dependency(:med_ex),
          MedFabric.BuildSources.med_ex_dependency(:med_ex_opus),
          MedFabric.BuildSources.med_ex_dependency(:med_ex_rtc),
          {:bandit, "~> 1.6"},
          {:plug, "~> 1.16"}
        ] ++ dev_deps

      MedFabric.BuildSources.resolve(defaults, __DIR__, Path.expand("../..", __DIR__))
    else
      {[
         {:med_ex, "~> 0.3.1", hex: "med_ex", repo: "hexpm"},
         {:med_ex_opus, "~> 0.2.1", hex: "med_ex_opus", repo: "hexpm"},
         {:med_ex_rtc, "~> 0.2.1", hex: "med_ex_rtc", repo: "hexpm"},
         {:bandit, "~> 1.6"},
         {:plug, "~> 1.16"}
       ] ++ dev_deps, []}
    end
  end

  defp package do
    [
      files:
        ~w(.formatter.exs mix.exs VERSION LICENSE README.md CHANGELOG.md assets config guides lib),
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
      {"guides/isolation_model.md", title: "Isolation Model"}
    ]

    [
      main: "readme",
      logo: "assets/preview.svg",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "mf_preview-v#{@version}",
      source_url_pattern:
        "#{@source_url}/blob/mf_preview-v#{@version}/apps/preview/%{path}#L%{line}",
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
        "Supervision & HTTP": [
          MedFabric.Preview.Application,
          MedFabric.Preview.Endpoint
        ],
        "Media & Signaling": [
          MedFabric.Preview.Peer
        ]
      ]
    ]
  end
end
