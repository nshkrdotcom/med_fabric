<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

Med Fabric is a deployable Elixir reference exam that brings together two-way
WebRTC talkback, live diagnostic audio capture with
[MedEx](https://github.com/nshkrdotcom/med_ex), and clinician review of
recordings and pulse-rate measurements. PostgreSQL records acceptance and queues
HL7 FHIR R4 delivery.

## Quickstart

On Ubuntu 26.04 with the pinned toolchains active (`.tool-versions`, PostgreSQL
18, and Temurin JDK `21.0.9+10` or external `DATABASE_URL` / `FHIR_BASE_URL`):

```bash
./onboard.sh --integration
bash ops/verify_browser.sh --release
```

Start with the [browser-to-record guide](guides/browser_to_record.md) for full
prerequisites, running the compiled `mf_exam` Mix release directly, the manual
listening check, and local workspace mode.

Read the [architecture and roadmap](guides/architecture_and_roadmap.md) for
clinical ownership boundaries, PostgreSQL/FHIR contracts, and the 12-use-case
roadmap.

## Projects

| Path | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Validate audio and vital evidence constructors in pure Elixir |
| [core/store](core/store/README.md) | Commit encounters, evidence, acceptance, and outbox intents atomically in PostgreSQL |
| [core/interop](core/interop/README.md) | Map reviewed recordings and pulse rates to HL7 FHIR R4 and confirm idempotent delivery |
| [apps/exam](apps/exam/README.md) | Boot Phoenix, authorize encounters, host talkback/preview/PCM sockets, and serve the review UI |

## License

Released under the MIT License.
