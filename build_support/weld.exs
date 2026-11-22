[
  workspace: [root: "..", project_globs: ["core/*", "apps/*"]],
  classify: [tooling: ["."]],
  artifacts: [
    med_fabric: [
      mode: :monolith,
      roots: ["apps/exam", "apps/steth"],
      package: [
        name: "med_fabric",
        otp_app: :med_fabric,
        version: "0.1.0",
        elixir: "~> 1.18",
        description: "Device-assisted remote encounters",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/nshkrdotcom/med_fabric"}
      ],
      output: [docs: ["README.md", "CHANGELOG.md", "LICENSE"], assets: ["assets/med_fabric.svg"]],
      verify: [hex_build: false, hex_publish: false]
    ]
  ]
]
