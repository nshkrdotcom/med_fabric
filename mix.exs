Code.require_file("build_support/workspace.exs", __DIR__)

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
        {:blitz, "0.4.1", only: [:dev, :test], runtime: false},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:ex_doc, "~> 0.40", only: :dev, runtime: false}
      ],
      aliases: MedFabric.Build.Workspace.aliases()
    ]
  end

  def cli, do: [preferred_envs: [setup: :dev, test: :dev, credo: :dev, dialyzer: :dev, quality: :dev, docs: :dev]]

  defp docs do
    guides =
      ~w(guides/browser_to_record.md guides/media_verification.md guides/architecture_and_roadmap.md guides/handheld_demo.md guides/preview_isolation.md guides/releasing_exam.md guides/failure_matrix.md guides/operations_and_telemetry.md guides/security_and_clinical_boundary.md guides/clinical_core.md)

    projects = [
      {"core/domain/README.md", filename: "domain", title: "Domain"},
      {"core/store/README.md", filename: "store", title: "Store"},
      {"core/interop/README.md", filename: "interop", title: "Interop"},
      {"apps/exam/README.md", filename: "exam", title: "Exam"},
      {"apps/handheld/README.md", filename: "handheld", title: "Handheld"},
      {"apps/preview/README.md", filename: "preview", title: "Preview"}
    ]

    app_guides = [
      {"apps/exam/guides/getting_started.md",
       filename: "exam_getting_started", title: "Exam: Getting Started"},
      {"apps/exam/guides/browser_to_record.md",
       filename: "exam_browser_to_record", title: "Exam: Browser to Record"},
      {"apps/exam/guides/handheld_integration.md",
       filename: "exam_handheld_integration", title: "Exam: Handheld Integration"},
      {"apps/exam/guides/architecture.md",
       filename: "exam_architecture", title: "Exam: Architecture"},
      {"apps/handheld/guides/getting_started.md",
       filename: "handheld_getting_started", title: "Handheld: Getting Started"},
      {"apps/handheld/guides/spool_and_recovery.md",
       filename: "handheld_spool_and_recovery", title: "Handheld: Spool & Recovery"},
      {"apps/handheld/guides/deployment.md",
       filename: "handheld_deployment", title: "Handheld: Deployment"},
      {"apps/preview/guides/getting_started.md",
       filename: "preview_getting_started", title: "Preview: Getting Started"},
      {"apps/preview/guides/isolation_model.md",
       filename: "preview_isolation_model", title: "Preview: Isolation Model"}
    ]

    [
      main: "readme",
      before_closing_body_tag: &docs_diagrams/1,
      logo: "assets/med_fabric.svg",
      assets: %{
        "assets" => "assets",
        "apps/exam/assets" => "assets",
        "apps/handheld/assets" => "assets",
        "apps/preview/assets" => "assets",
        "core/domain/assets" => "assets",
        "core/interop/assets" => "assets",
        "core/store/assets" => "assets"
      },
      extras:
        [
          {"README.md", filename: "readme", title: "Overview"},
          {"CHANGELOG.md", filename: "changelog", title: "Changelog"},
          {"LICENSE", filename: "license", title: "License"}
        ] ++ guides ++ projects ++ app_guides,
      groups_for_extras: [
        Overview: ["README.md"],
        Guides: guides,
        Projects: Enum.map(projects, &elem(&1, 0)),
        "Package Guides": Enum.map(app_guides, &elem(&1, 0)),
        Release: ~w(CHANGELOG.md LICENSE)
      ]
    ]
  end

  defp docs_diagrams(:html), do: File.read!(Path.join(__DIR__, "build_support/docs_hook.html"))

  defp docs_diagrams(_format), do: ""
end
