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

## Run the exam candidate

The 0.2 candidate combines two-way conversation, independently selected diagnostic audio and clinician-entered pulse measurements. A patient can recover a recording outcome after reconnecting. Clinicians can seek in a verified WAV, review its source and time, and deliver the accepted observation to the encounter’s own FHIR destination.

From this checkout, with sibling MedEx and Mix Workspace Ops checkouts and the medical registry installed, run the SDK and Fabric QC sequence:

```bash
bash ops/qc_candidate.sh
```

The command builds the unpublished SDK from source and runs the exam release with that SDK. Allow time for native dependencies, Dialyzer, PostgreSQL, HAPI and Chromium. For a live exam, follow the operator setup. For an actual TURN demonstration use the two-endpoint media procedure. [Browser-to-record guide](guides/browser_to_record.md) · [Remote media verification](guides/media_verification.md) · [Architecture and roadmap](guides/architecture_and_roadmap.md)

## Projects

| Path | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Validate audio and vital evidence constructors in pure Elixir |
| [core/store](core/store/README.md) | Commit encounters, evidence, acceptance, and outbox intents atomically in PostgreSQL |
| [core/interop](core/interop/README.md) | Map reviewed recordings and pulse rates to HL7 FHIR R4 and confirm idempotent delivery |
| [apps/exam](apps/exam/README.md) | Boot Phoenix, authorize encounters, host talkback/preview/PCM sockets, and serve the review UI |

## License

Released under the MIT License.
