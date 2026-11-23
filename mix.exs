defmodule MedFabric.Workspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_fabric_workspace,
      version: "0.1.0",
      elixir: "~> 1.20",
      name: "Med Fabric",
      docs: docs(),
      deps: [
        {:blitz, "~> 0.4.1", runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.40", only: :dev, runtime: false}
      ],
      dialyzer: [plt_add_apps: [:mix, :blitz]],
      aliases: [
        setup: ["blitz.workspace deps_get --"],
        test: ["blitz.workspace test --"],
        quality: ["blitz.workspace quality --"]
      ],
      blitz_workspace: [
        root: __DIR__,
        projects: Path.wildcard("{apps,core}/*/mix.exs") |> Enum.map(&Path.dirname/1),
        isolation: [deps_path: true, build_path: true, lockfile: true],
        parallelism: [
          multiplier: :auto,
          base: [
            deps_get: 4,
            test: 4,
            quality: 4
          ],
          overrides: []
        ],
        tasks: [
          deps_get: [args: ["deps.get"], preflight?: false],
          test: [args: ["test"], mix_env: :test],
          quality: [args: ["quality"], mix_env: :dev]
        ]
      ]
    ]
  end

  defp docs do
    guides = ~w(guides/browser_to_record.md guides/architecture_and_roadmap.md)

    projects = [
      {"core/domain/README.md", filename: "domain", title: "Domain"},
      {"core/store/README.md", filename: "store", title: "Store"},
      {"core/interop/README.md", filename: "interop", title: "Interop"},
      {"apps/exam/README.md", filename: "exam", title: "Exam"}
    ]

    [
      main: "readme",
      logo: "assets/med_fabric.svg",
      assets: %{"assets" => "assets"},
      extras: ~w(README.md CHANGELOG.md LICENSE) ++ guides ++ projects,
      groups_for_extras: [
        Overview: ~w(README.md CHANGELOG.md LICENSE),
        Guides: guides,
        Projects: Enum.map(projects, &elem(&1, 0))
      ]
    ]
  end
end
