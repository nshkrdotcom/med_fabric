# Changelog

All notable changes to `mf_exam` will be documented in this file.

## 0.1.0 - 2026-11-24

- Initial Hex release of the Med Fabric Exam server (`mf_exam`), composing `mf_domain`, `mf_store`, and `mf_interop` into a standalone Phoenix + LiveView application.
- Paired acoustic/ECG and PLXS spot-check device admission, TLS replay ingestion, durable PostgreSQL acceptance, and idempotent HL7 FHIR R4 delivery.
- Two-way WebRTC browser talkback, lossless 48 kHz mono PCM16LE WAV capture, and optional isolated `mf_preview` monitoring gateway.
- Consumes public `med_ex ~> 0.2.0` from Hex with standalone HexDocs navigation and guides.
