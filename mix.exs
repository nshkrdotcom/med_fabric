defmodule MedFabric.Workspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_fabric_workspace,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:blitz, "~> 0.4.1", runtime: false},
        {:weld, "~> 0.10.0", only: [:dev, :test], runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      ],
      dialyzer: [plt_add_apps: [:mix, :blitz, :weld]],
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
end
