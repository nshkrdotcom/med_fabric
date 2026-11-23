defmodule MedFabric.Workspace.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_fabric_workspace,
      version: __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim(),
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
    guides =
      ~w(guides/browser_to_record.md guides/media_verification.md guides/architecture_and_roadmap.md)

    projects = [
      {"core/domain/README.md", filename: "domain", title: "Domain"},
      {"core/store/README.md", filename: "store", title: "Store"},
      {"core/interop/README.md", filename: "interop", title: "Interop"},
      {"apps/exam/README.md", filename: "exam", title: "Exam"}
    ]

    [
      main: "readme",
      before_closing_body_tag: &docs_diagrams/1,
      logo: "assets/med_fabric.svg",
      assets: %{"assets" => "assets"},
      extras:
        [
          {"README.md", filename: "readme", title: "Overview"},
          {"CHANGELOG.md", filename: "changelog", title: "Changelog"},
          {"LICENSE", filename: "license", title: "License"}
        ] ++ guides ++ projects,
      groups_for_extras: [
        Overview: ["README.md"],
        Guides: guides,
        Projects: Enum.map(projects, &elem(&1, 0)),
        Release: ~w(CHANGELOG.md LICENSE)
      ]
    ]
  end

  defp docs_diagrams(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js"></script>
    <script>
      document.addEventListener("DOMContentLoaded", () => {
        const codeBlocks = document.querySelectorAll("pre code.mermaid");
        if (!codeBlocks.length || !window.mermaid) return;
        mermaid.initialize({startOnLoad: false, securityLevel: "strict"});
        const nodes = Array.from(codeBlocks, code => {
          const diagram = document.createElement("div");
          diagram.className = "mermaid";
          diagram.textContent = code.textContent;
          code.parentElement.replaceWith(diagram);
          return diagram;
        });
        mermaid.run({nodes});
      });
    </script>
    """
  end

  defp docs_diagrams(_format), do: ""
end
