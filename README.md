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

## Run the clinical workflows

The exam supports a guided synthetic acoustic/ECG acquisition and a PLXS spot check with delayed delivery, alongside browser WAV and manual pulse. A device credential plus a clinician's encounter grant authorizes capture. Review binds the exact immutable manifest. Each accepted PLXS metric has an independent FHIR delivery record.

Select the matching MedEx source and use ordinary Mix in each application. The temporary default Git branch must be replaced with the verified reachable implementation commit after integration. No MedEx or Fabric package publication is part of this change.

[Handheld setup and process acceptance](guides/handheld_demo.md) · [Browser to record](guides/browser_to_record.md) · [Optional monitor service](guides/preview_isolation.md)

## Projects

| Path | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Validate audio and vital evidence constructors in pure Elixir |
| [core/store](core/store/README.md) | Commit encounters, evidence, acceptance, and outbox intents atomically in PostgreSQL |
| [core/interop](core/interop/README.md) | Map reviewed recordings and pulse rates to HL7 FHIR R4 and confirm idempotent delivery |
| [apps/exam](apps/exam/README.md) | Boot Phoenix, authorize encounters, host talkback/preview/PCM sockets, and serve the review UI |
| [apps/handheld](apps/handheld/README.md) | Standalone synthetic peripheral client, TLS transport and durable spool |
| [apps/preview](apps/preview/README.md) | Optional isolated monitor encoding, RTC and signaling |

## License

Released under the MIT License.
