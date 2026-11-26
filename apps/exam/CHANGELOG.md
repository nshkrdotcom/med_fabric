# Changelog

## 0.2.1 — 2026-11-26

- Report clinical ineligibility separately from a concurrent review change.
- Use shared durable receipt progression, retire the writer after a failed scoped transaction, and report FHIR mapping failures separately.

## 0.2.0 - 2026-11-25

- Reject empty Preview signing credentials and include the hardening guides in projected package docs.
- Support file-based deployment configuration (`/etc/med_fabric/exam.json`).
- Remove the legacy Membrane `:ratio` Git override now that `med_ex_opus ~> 0.2.0` uses a standalone C `libopus` Port encoder, allowing combined Mix projects to resolve cleanly from Hex.
- Require `med_ex ~> 0.3.0` (and `med_ex_opus ~> 0.2.0`, `med_ex_rtc ~> 0.2.0` when legacy media is enabled).

## 0.1.1 - 2026-11-25

- Verify segment occurrence, contiguous review coverage, and fenced capacity completion.
- Enable host-fenced 15-frame pipelined batching (`checkpoint_ms: :manual`), remove redundant finalization scans while preserving full byte verification on crash recovery and review, and emit `:telemetry` checkpoint timings.
- Allow one active acquisition per encounter and profile, admit supported nonzero source epochs, and derive synthetic clock validity from the observed probe span.
- Restart the optional preview relay without restarting the database pool or active capture writers. Keep live ECG available without a sidecar.
- Require MedEx 0.2.1.

All notable changes to `mf_exam` will be documented in this file.

## 0.1.0 - 2026-11-24

- Initial Hex release of the Med Fabric Exam server (`mf_exam`), composing `mf_domain`, `mf_store`, and `mf_interop` into a standalone Phoenix + LiveView application.
- Paired acoustic/ECG and PLXS spot-check device admission, TLS replay ingestion, durable PostgreSQL acceptance, and idempotent HL7 FHIR R4 delivery.
- Two-way WebRTC browser talkback, lossless 48 kHz mono PCM16LE WAV capture, and optional isolated `mf_preview` monitoring gateway.
- Consumes public `med_ex ~> 0.2.0` from Hex with standalone HexDocs navigation and guides.
