defmodule MfExam.MixProject do
  use Mix.Project

  def project do
    [
      app: :mf_exam,
      version: "0.1.0",
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
      {:decimal, "~> 3.2"},
      {:jason, "~> 1.4"},
      {:med_ex, "~> 0.2.0", [hex: "med_ex", repo: "hexpm"]},
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
        "apps/exam/README.md",
        "apps/exam/assets",
        "apps/exam/guides/architecture.md",
        "apps/exam/guides/browser_to_record.md",
        "apps/exam/guides/getting_started.md",
        "apps/exam/guides/handheld_integration.md",
        "config",
        "lib",
        "mix.exs",
        "priv"
      ]
    ]
  end

  defp docs do
    Keyword.put(
      [
        assets: %{"apps/exam/assets" => "assets"},
        source_ref: "mf_exam-v0.1.0",
        source_url: "https://github.com/nshkrdotcom/med_fabric",
        logo: "apps/exam/assets/exam.svg",
        main: "readme",
        extras: [
          "apps/exam/CHANGELOG.md",
          "apps/exam/LICENSE",
          "apps/exam/README.md",
          "apps/exam/guides/architecture.md",
          "apps/exam/guides/browser_to_record.md",
          "apps/exam/guides/getting_started.md",
          "apps/exam/guides/handheld_integration.md"
        ]
      ],
      :before_closing_body_tag,
      fn
        :html ->
          "<script src=\"https://cdn.jsdelivr.net/npm/mermaid@11.12.2/dist/mermaid.min.js\"></script>\n<script>\ndocument.addEventListener(\"DOMContentLoaded\", () => {\n  const diagrams = document.querySelectorAll(\"pre code.mermaid\");\n  if (!diagrams.length || !window.mermaid) return;\n  mermaid.initialize({startOnLoad: false, securityLevel: \"strict\"});\n  for (const code of diagrams) {\n    const diagram = document.createElement(\"div\");\n    diagram.className = \"mermaid\";\n    diagram.textContent = code.textContent;\n    code.parentElement.replaceWith(diagram);\n  }\n  mermaid.run();\n});\n</script>\n"

        _ ->
          ""
      end
    )
  end
end
