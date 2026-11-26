sources_path = Path.expand("../../config/sources.exs", __DIR__)
if File.regular?(sources_path), do: Code.require_file(sources_path)

defmodule MedFabric.Exam.MixProject do
  use Mix.Project

  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()
  @source_url "https://github.com/nshkrdotcom/med_fabric"

  def project do
    legacy_media? = System.get_env("MF_EXAM_LEGACY_MEDIA") == "1"
    profile = if legacy_media?, do: :legacy_media, else: :default

    {deps, paths} =
      if Code.ensure_loaded?(MedFabric.BuildSources) do
        MedFabric.BuildSources.resolve(
          deps(legacy_media?),
          __DIR__,
          Path.expand("../..", __DIR__),
          profile: profile
        )
      else
        {deps(legacy_media?), []}
      end

    [
      app: :mf_exam,
      version: @version,
      elixir: "~> 1.20",
      name: "Med Fabric Exam",
      description: "Connected remote clinical examination server built on MedEx",
      source_url: @source_url,
      homepage_url: @source_url,
      dialyzer: [plt_add_apps: [:mix]],
      aliases: [quality: ["credo --strict", "dialyzer --force-check"]],
      deps: deps,
      docs: docs()
    ] ++ paths
  end

  def application do
    [mod: {MedFabric.Exam.Application, []}]
  end

  defp deps(legacy_media?) do
    med_ex_dep =
      if Code.ensure_loaded?(MedFabric.BuildSources),
        do: MedFabric.BuildSources.med_ex_dependency(:med_ex),
        else: {:med_ex, "~> 0.2.1"}

    [
      {:mf_domain, path: "../../core/domain"},
      {:mf_store, path: "../../core/store"},
      {:mf_interop, path: "../../core/interop"},
      med_ex_dep,
      {:decimal, "~> 3.2"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.0"},
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.5", only: :dev, runtime: false}
    ] ++
      if(legacy_media?,
        do: [
          MedFabric.BuildSources.med_ex_dependency(:med_ex_opus),
          MedFabric.BuildSources.med_ex_dependency(:med_ex_rtc)
        ],
        else: []
      )
  end

  defp docs do
    guides = [
      {"guides/getting_started.md", title: "Getting Started"},
      {"guides/browser_to_record.md", title: "Browser to Record"},
      {"guides/handheld_integration.md", title: "Handheld Integration"},
      {"guides/architecture.md", title: "Architecture"}
    ]

    [
      main: "readme",
      logo: "assets/exam.svg",
      assets: %{"assets" => "assets"},
      source_url: @source_url,
      source_ref: "mf_exam-v#{@version}",
      extras:
        [
          {"README.md", filename: "readme", title: "Overview"}
        ] ++
          guides ++
          [
            {"CHANGELOG.md", title: "Changelog"},
            {"LICENSE", title: "License"}
          ],
      groups_for_extras: [
        Overview: ["README.md"],
        Guides: Enum.map(guides, &elem(&1, 0)),
        Release: ["CHANGELOG.md", "LICENSE"]
      ],
      groups_for_modules: [
        "Application & Context": [
          MedFabric.Exam,
          MedFabric.Exam.Application,
          MedFabric.Exam.Context,
          MedFabric.Exam.Barrier
        ],
        "Device Ingestion & Workflow": [
          MedFabric.Exam.DeviceIngress,
          MedFabric.Exam.DeviceManifest,
          MedFabric.Exam.DeviceWorkflow,
          MedFabric.Exam.DeviceReviews,
          MedFabric.Exam.DeviceExpiry,
          MedFabric.Exam.DeviceRootLock,
          MedFabric.Exam.ClockObservations
        ],
        "Recordings & Preview": [
          MedFabric.Exam.Artifact,
          MedFabric.Exam.Recordings,
          MedFabric.Exam.PreviewGateway,
          MedFabric.Exam.ICE
        ],
        "Web & LiveView": [
          MedFabric.ExamWeb.Endpoint,
          MedFabric.ExamWeb.Router,
          MedFabric.ExamWeb.Layout,
          MedFabric.ExamWeb.ExamLive,
          MedFabric.ExamWeb.DeviceLive,
          MedFabric.ExamWeb.DeviceAction,
          MedFabric.ExamWeb.DeviceSegment,
          MedFabric.ExamWeb.DeviceSocket,
          MedFabric.ExamWeb.PCMSocket,
          MedFabric.ExamWeb.UserSocket,
          MedFabric.ExamWeb.SignalingChannel,
          MedFabric.ExamWeb.TalkbackChannel,
          MedFabric.ExamWeb.ProxyIdentity
        ]
      ]
    ]
  end
end
