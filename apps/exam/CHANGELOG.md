# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-26

### Breaking changes

- Unify browser microphone, paired waveform and event acquisition under revision-2
  source authority, explicit fenced writers, canonical receipts and manifests.
- Remove the browser WAV recorder, SDK asset route and in-process media path;
  retain bounded Exam-owned worklet capture, verified segment playback and
  independently authorized direct talkback.
- Move clinical validation to pure Domain and durable SQL ownership to explicit
  Store operations. Commit native decision, observations and delivery intent
  atomically without FHIR mapping or destination availability.
- Add pinned, attempt-bound delivery with distinct blocked, unresolved, retryable,
  conflict and confirmed states and safe dispatch/confirmation predicates.
- Replace upgrade SQL with one fresh revision-2 schema, immutable deployment UUID,
  root ownership and fail-closed restore/startup requirements.
- Keep one Weld monolith containing Exam, Domain, Store and Interop; consume
  med_ex ~> 0.4.0 without optional provider dependencies.

### Tests and operations

- Add native acceptance, source authority, browser, recovery, schema and outbox
  tests; update source lanes, release inventory and qualification instructions.
- Native service/fault/detached/soak gates must pass before any publication.

## [0.2.1] - 2026-11-26

- Report clinical ineligibility separately from a concurrent review change.
- Use shared durable receipt progression, retire the writer after a failed scoped transaction, and report FHIR mapping failures separately.

## [0.2.0] - 2026-11-25

- Reject empty Preview signing credentials and include the hardening guides in projected package docs.
- Support file-based deployment configuration (`/etc/med_fabric/exam.json`).
- Remove the legacy Membrane `:ratio` Git override now that `med_ex_opus ~> 0.2.0` uses a standalone C `libopus` Port encoder, allowing combined Mix projects to resolve cleanly from Hex.
- Require `med_ex ~> 0.3.0` (and `med_ex_opus ~> 0.2.0`, `med_ex_rtc ~> 0.2.0` when legacy media is enabled).

## [0.1.1] - 2026-11-25

- Verify segment occurrence, contiguous review coverage, and fenced capacity completion.
- Enable host-fenced 15-frame pipelined batching (`checkpoint_ms: :manual`), remove redundant finalization scans while preserving full byte verification on crash recovery and review, and emit `:telemetry` checkpoint timings.
- Allow one active acquisition per encounter and profile, admit supported nonzero source epochs, and derive synthetic clock validity from the observed probe span.
- Restart the optional preview relay without restarting the database pool or active capture writers. Keep live ECG available without a sidecar.
- Require MedEx 0.2.1.

All notable changes to `mf_exam` will be documented in this file.

## [0.1.0] - 2026-11-24

- Initial Hex release of the Med Fabric Exam server (`mf_exam`), composing `mf_domain`, `mf_store`, and `mf_interop` into a standalone Phoenix + LiveView application.
- Paired acoustic/ECG and PLXS spot-check device admission, TLS replay ingestion, durable PostgreSQL acceptance, and idempotent HL7 FHIR R4 delivery.
- Two-way WebRTC browser talkback, lossless 48 kHz mono PCM16LE WAV capture, and optional isolated `mf_preview` monitoring gateway.
- Consumes public `med_ex ~> 0.2.0` from Hex with standalone HexDocs navigation and guides.

[0.3.0]: https://github.com/nshkrdotcom/med_fabric/compare/mf_exam-v0.2.1...mf_exam-v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/med_fabric/compare/mf_exam-v0.2.0...mf_exam-v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/med_fabric/compare/mf_exam-v0.1.1...mf_exam-v0.2.0
[0.1.1]: https://github.com/nshkrdotcom/med_fabric/compare/mf_exam-v0.1.0...mf_exam-v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/med_fabric/releases/tag/mf_exam-v0.1.0
