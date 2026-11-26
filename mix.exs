defmodule MfExam.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_exam,
      version: "0.2.1",
      build_path: "_build",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: erlc_paths(Mix.env()),
      deps: deps(),
      description: "Connected remote clinical examination server built on MedEx",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [mod: {MfExam.Application, []}, extra_applications: [:logger]]
  end

  def elixirc_paths(:test), do: ["lib", "test/support"]
  def elixirc_paths(_env), do: ["lib"]
  def erlc_paths(:test), do: []
  def erlc_paths(_env), do: []

  defp deps do
    [
      {:bandit, "~> 1.6"},
      {:db_connection, "~> 2.10.3"},
      {:decimal, "~> 3.2"},
      {:jason, "~> 1.4"},
      {:med_ex, "~> 0.3.1", [hex: "med_ex", repo: "hexpm"]},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:postgrex, "~> 0.23"},
      {:req, "~> 0.7.5"},
      {:websock_adapter, "~> 0.5"},
      {:credo, "~> 1.7", [only: [:dev, :test], runtime: false]},
      {:dialyxir, "~> 1.4", [only: [:dev, :test], runtime: false]},
      {:ex_doc, "~> 0.40.5", [only: :dev, runtime: false]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: [],
      links: %{"Source" => "https://github.com/nshkrdotcom/med_fabric"},
      files: [
        ".formatter.exs",
        "README.md",
        "apps/exam/CHANGELOG.md",
        "apps/exam/LICENSE",
        "apps/exam/assets",
        "apps/exam/guides/architecture.md",
        "apps/exam/guides/browser_to_record.md",
        "apps/exam/guides/getting_started.md",
        "apps/exam/guides/handheld_integration.md",
        "config",
        "guides",
        "lib",
        "mix.exs",
        "priv"
      ]
    ]
  end

  defp docs do
    Keyword.put(
      [
        groups_for_extras: [
          {"Overview", ["README.md"]},
          {"Guides",
           [
             "apps/exam/guides/getting_started.md",
             "apps/exam/guides/browser_to_record.md",
             "apps/exam/guides/handheld_integration.md",
             "apps/exam/guides/architecture.md",
             "guides/failure_matrix.md",
             "guides/operations_and_telemetry.md",
             "guides/security_and_clinical_boundary.md",
             "guides/core_api_and_compatibility.md"
           ]},
          {"Release", ["apps/exam/CHANGELOG.md", "apps/exam/LICENSE"]}
        ],
        assets: %{"apps/exam/assets" => "assets"},
        source_ref: "mf_exam-v0.2.1",
        source_url: "https://github.com/nshkrdotcom/med_fabric",
        logo: "apps/exam/assets/exam.svg",
        main: "readme",
        extras: [
          {"README.md", [title: "Overview"]},
          {"apps/exam/CHANGELOG.md", [title: "Changelog"]},
          {"apps/exam/LICENSE", [title: "License"]},
          {"apps/exam/guides/architecture.md", [title: "Architecture"]},
          {"apps/exam/guides/browser_to_record.md", [title: "Browser to Record"]},
          {"apps/exam/guides/getting_started.md", [title: "Getting Started"]},
          {"apps/exam/guides/handheld_integration.md", [title: "Handheld Integration"]},
          {"guides/core_api_and_compatibility.md", [title: "Core API and Compatibility"]},
          {"guides/failure_matrix.md", [title: "Failure Matrix"]},
          {"guides/operations_and_telemetry.md", [title: "Operations and Telemetry"]},
          {"guides/security_and_clinical_boundary.md", [title: "Security and Clinical Boundary"]}
        ]
      ],
      :before_closing_body_tag,
      fn
        :html ->
          "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js\"></script>\n<script>\nwindow.addEventListener(\"exdoc:loaded\", () => {\nconst codeBlocks = document.querySelectorAll(\"pre code.mermaid\");\nif (!codeBlocks.length || !window.mermaid) return;\nmermaid.initialize({\nstartOnLoad: false,\nsecurityLevel: \"strict\",\ntheme: document.body.classList.contains(\"dark\") ? \"dark\" : \"default\"\n});\nconst nodes = Array.from(codeBlocks, code => {\nconst diagram = document.createElement(\"div\");\ndiagram.className = \"mermaid\";\ndiagram.textContent = code.textContent;\ncode.parentElement.replaceWith(diagram);\nreturn diagram;\n});\nmermaid.run({nodes});\n});\n</script>\n"

        _ ->
          ""
      end
    )
  end
end
