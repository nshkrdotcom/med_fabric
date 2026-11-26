# Changelog

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
