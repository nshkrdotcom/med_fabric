<p align="center">
  <img src="https://raw.githubusercontent.com/nshkrdotcom/med_fabric/main/apps/exam/assets/exam.svg" alt="Med Fabric Exam logo" width="200" />
</p>

<h1 align="center">Med Fabric Exam</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric/tree/main/apps/exam"><img src="https://img.shields.io/badge/GitHub-mf__exam-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/apps/exam/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_exam` is the deployable Phoenix + LiveView remote clinical examination
server in [Med Fabric](https://github.com/nshkrdotcom/med_fabric). Built on
[`med_ex`](https://hex.pm/packages/med_ex), it composes encounter domain rules,
transactional PostgreSQL persistence, and idempotent HL7 FHIR R4 delivery into
a single review and acquisition server.

## Installation

Add `mf_exam` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mf_exam, "~> 0.1.0"}
  ]
end
```

`mf_exam` requires Elixir `~> 1.20` (OTP 29), PostgreSQL for durable encounter
and outbox storage, and the base `med_ex ~> 0.2.0` SDK.

## Workflows

- **Paired acoustic & ECG examination:** Admits enrolled handheld devices over
  TLS, ingests resumable waveform replays, persists authoritative evidence and
  progress, and renders verified acoustic segments, explicit gaps, and clock
  uncertainty bounds for clinical review.
- **Pulse-oximetry spot checks (PLXS):** Accepts replayed handheld spot-check
  collections, tracks clinician acceptance or repeat requests, and commits each
  accepted observation and its retryable FHIR delivery intent atomically.
- **Browser examination:** Hosts direct two-way WebRTC talkback alongside
  lossless 48 kHz mono PCM16LE WAV capture and clinician-entered pulse rate.
- **Optional isolated monitor (`mf_preview`):** Forwards latest-only software
  monitor frames to an isolated loopback [`mf_preview`](https://hex.pm/packages/mf_preview)
  BEAM process and issues short-lived signed viewer tokens without exposing
  database credentials or clinical artifacts.

## Guides

- [Getting Started](https://mf-exam.hexdocs.pm/0.1.0/getting_started.html) — Prerequisites, configuration,
  and Mix release startup.
- [Browser to Record](https://mf-exam.hexdocs.pm/0.1.0/browser_to_record.html) — Two-way talkback, lossless
  WAV capture, review, and FHIR R4 export.
- [Handheld Integration](https://mf-exam.hexdocs.pm/0.1.0/handheld_integration.html) — Device admission,
  TLS replay, and spot-check review.
- [Architecture](https://mf-exam.hexdocs.pm/0.1.0/architecture.html) — Domain, store, interop, and web
  boundaries.

## Optional Legacy Media Profile

The published Hex package depends only on base `:med_ex` (zero native media or
Git dependencies). When running from a source checkout, set
`MF_EXAM_LEGACY_MEDIA=1` to build the optional in-VM browser media profile in
its own isolated Mix context.

## License

Released under the [MIT License](https://github.com/nshkrdotcom/med_fabric/blob/main/apps/exam/LICENSE).
