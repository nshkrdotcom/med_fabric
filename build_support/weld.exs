med_ex_ref = "c26b481d6b8115e3522c8c65d59203ba2dce68f5"

[
  workspace: [root: "..", project_globs: ["core/*", "apps/*"]],
  classify: [tooling: ["."]],
  dependencies: [
    med_core: [
      opts: [
        github: "nshkrdotcom/med_ex",
        ref: med_ex_ref,
        subdir: "core/med_core",
        override: true
      ]
    ],
    med_rtc: [
      opts: [
        github: "nshkrdotcom/med_ex",
        ref: med_ex_ref,
        subdir: "core/med_rtc"
      ]
    ]
  ],
  artifacts: [
    med_fabric: [
      mode: :monolith,
      roots: ["apps/exam", "apps/steth"],
      package: [
        name: "med_fabric",
        otp_app: :med_fabric,
        version: "0.1.0",
        elixir: "~> 1.18",
        description: "Device-assisted remote clinical encounters",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/nshkrdotcom/med_fabric"}
      ],
      output: [docs: ["README.md", "CHANGELOG.md", "LICENSE"], assets: ["assets/med_fabric.svg"]],
      verify: [hex_build: false, hex_publish: false]
    ]
  ]
]
