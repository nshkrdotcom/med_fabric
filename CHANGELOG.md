# Med Fabric changelog

## Unreleased

- Add a standalone example that exercises all six published Hex packages, including native Opus encoding and WebRTC delivery.

## 0.3.1 — 2026-11-26

- Preserve fresh monitor audio across gap-only batches and distinguish ineligible clinical measurements in Exam.
- Use MedEx receipt progression in Exam and Handheld, retire ingress after a failed database transaction, and report FHIR mapping failures separately from clinical eligibility.
- Isolate local monitor processing from authoritative paired capture. Durable spool batches, upload and operator stop continue through a stalled or failed monitor.

## 0.3.0 — 2026-11-25

- Reject empty Preview credentials and out-of-range environment listener ports;
  document host-owned runtime configuration for Preview Hex consumers.
- Include frozen C sources, Makefiles, explicit Opus archive bytes, and native
  cache selection in source build identity so stale native artifacts are not reused.
  Require an absolute `MED_EX_OPUS_TARBALL` path so consumer and provider builds
  identify the same offline archive, preserving symlink traversal in that path.
- Keep native qualification on locked Hex packages unless `--med-ex-project`
  explicitly selects a candidate; ignore stale staging pointers by default.
- Repair the failure-matrix citation guard and add direct regression cases.
  Register the hardening guides in workspace and projected Exam docs, correct
  their proof scope, and render Mermaid on each ExDoc page load with the current theme.
- Support file-based deployment configuration (`/etc/med_fabric/{exam,preview}.json`) across Exam and Preview.
- Consolidate media dependencies on `med_ex_opus ~> 0.2.0` (Port-isolated C11 `libopus` encoder) and remove the legacy Membrane `:ratio` Git override from Exam and combined Mix consumer guides.
- Add failure-matrix, operations/telemetry, security/clinical-boundary, and core-API/compatibility guides plus `ops/check_hardening.exs`.
- Align `mf_exam 0.2.0`, `mf_preview 0.2.0`, and `mf_handheld 0.2.0` on `med_ex ~> 0.3.0`, `med_ex_opus ~> 0.2.0`, `med_ex_rtc ~> 0.2.0`, and Weld `0.19.0`.

## 0.2.0 — 2026-11-25

- Add a Weld maintainer project and a release manifest for the standalone
  Exam package, including its internal applications, static files, and SQL migrations.

- Centralize transport membership checks and pass explicit workflow resources
  through recording and review services, including isolated integration tests.
- Reuse the SDK's WAV validation and preview clock rules; retain full-file
  integrity verification and same-descriptor range streaming.
- Keep recovered file identity separate from the reservation-backed continuity
  assertion in the recording coordinator.
- Run combined candidate QC against the exact prepared SDK release project and
  verify its packaged browser assets.
- Reserve acquisitions before PCM, recover finalized evidence after interruption, and serve verified, seekable recordings with bounded memory.
- Support encounter-scoped FHIR bindings, strict observation confirmation, distinct input devices, authenticated HTTPS ingress and TURN credentials.
- Verify segment occurrences and contiguous review ranges before committing clinical
  decisions, and preserve durable receipt identity when capture reaches capacity.
- Handle multi-sequence replay gaps and retire Preview peers on encoder failure.
- Enable host-fenced 15-frame pipelined batching with O(k) Handheld spool reclamation and verified 29-minute ext4 capture, finalization, and review.
- Allow one active acquisition per encounter and profile, admit supported nonzero source epochs, and derive synthetic clock validity from probes. Use the SDK interlock for Handheld command decisions and check the synthetic PLXS mapping against SDK serialization.
- Qualify Exam, Handheld and Preview 0.1.1 against MedEx 0.2.1. The release guide
  describes artifact preparation, qualification and publication.


## 0.1.0

- Compose two-way WebRTC talkback, independent diagnostic preview and recording, and manual pulse review in one exam.
- Commit clinical acceptance and its FHIR outbox intent atomically in PostgreSQL.
- Verify the Mix release with Chromium and native PostgreSQL and HAPI.
