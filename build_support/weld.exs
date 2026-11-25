root = Path.expand("..", __DIR__)
version = root |> Path.join("apps/exam/VERSION") |> File.read!() |> String.trim()
source_url = "https://github.com/nshkrdotcom/med_fabric"
exam_docs = ~w(
  apps/exam/README.md apps/exam/LICENSE apps/exam/CHANGELOG.md
  apps/exam/guides/getting_started.md apps/exam/guides/browser_to_record.md
  apps/exam/guides/handheld_integration.md apps/exam/guides/architecture.md
)

[
  workspace: [root: "..", project_globs: ["apps/exam", "core/*"]],
  artifacts: [
    mf_exam: [
      mode: :monolith,
      roots: ["apps/exam"],
      structural_inputs: ["apps/exam/VERSION"],
      package: [
        name: "mf_exam",
        otp_app: :mf_exam,
        version: version,
        elixir: "~> 1.20",
        description: "Connected remote clinical examination server built on MedEx",
        licenses: ["MIT"],
        links: %{"Source" => source_url},
        development_dependencies: [{:ex_doc, "~> 0.40.5", only: :dev, runtime: false}],
        docs: [
          main: "readme",
          logo: "apps/exam/assets/exam.svg",
          assets: %{"apps/exam/assets" => "assets"},
          source_url: source_url,
          source_ref: "mf_exam-v#{version}",
          mermaid: true
        ]
      ],
      output: [docs: exam_docs, assets: ["apps/exam/assets"]]
    ]
  ]
]
