root = Path.expand("..", __DIR__)
version = root |> Path.join("apps/exam/VERSION") |> File.read!() |> String.trim()
source_url = "https://github.com/nshkrdotcom/med_fabric"

guides = [
  {"apps/exam/guides/getting_started.md", "Getting Started"},
  {"apps/exam/guides/browser_to_record.md", "Browser to Record"},
  {"apps/exam/guides/handheld_integration.md", "Handheld Integration"},
  {"apps/exam/guides/architecture.md", "Architecture"},
  {"guides/failure_matrix.md", "Failure Matrix"},
  {"guides/operations_and_telemetry.md", "Operations and Telemetry"},
  {"guides/security_and_clinical_boundary.md", "Security and Clinical Boundary"},
  {"guides/core_api_and_compatibility.md", "Core API and Compatibility"}
]

guide_paths = Enum.map(guides, &elem(&1, 0))
release_docs = ["apps/exam/CHANGELOG.md", "apps/exam/LICENSE"]
exam_docs = guide_paths ++ release_docs

[
  workspace: [root: "..", project_globs: ["apps/exam", "core/*"]],
  artifacts: [
    mf_exam: [
      mode: :monolith,
      monolith_opts: [readme: "apps/exam/README.md"],
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
          extra_titles:
            Map.new(
              guides ++
                [
                  {"README.md", "Overview"},
                  {"apps/exam/CHANGELOG.md", "Changelog"},
                  {"apps/exam/LICENSE", "License"}
                ]
            ),
          groups_for_extras: [
            Overview: ["README.md"],
            Guides: guide_paths,
            Release: release_docs
          ],
          mermaid: true
        ]
      ],
      output: [docs: exam_docs, assets: ["apps/exam/assets"]]
    ]
  ]
]
