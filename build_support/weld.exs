[
  workspace: [root: "..", project_globs: ["core/*", "apps/*"]],
  classify: [
    tooling: ["."],
    proofs: ["apps/exam"]
  ],
  publication: [
    internal_only: ["."]
  ],
  artifacts: [
    med_fabric: [
      mode: :monolith,
      roots: [
        "core/domain",
        "core/runtime",
        "core/store",
        "core/interop"
      ],
      package: [
        name: "med_fabric",
        otp_app: :med_fabric,
        version: "0.1.0",
        elixir: "~> 1.18",
        description: "Reusable clinical encounter workflow libraries for Med Fabric",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/nshkrdotcom/med_fabric"}
      ],
      output: [
        docs: ["README.md", "CHANGELOG.md", "LICENSE"],
        assets: ["assets/med_fabric.svg"]
      ],
      verify: [hex_build: false, hex_publish: false]
    ]
  ]
]
