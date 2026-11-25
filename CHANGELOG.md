# Med Fabric changelog

## 0.2.0 — 2026-11-25

- Add a Weld 0.18.0 maintainer project and a release manifest for the standalone
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
- Allow concurrent multi-profile acquisitions per encounter, non-zero `source_epoch` admission, probe-derived clock validity bounds, and end-to-end exercise of `MedEx.ControlInterlock`, `MedEx.StatusEvent`, and `MedEx.Serialization.measurement/1`.
- Qualify Exam, Handheld and Preview 0.1.1 against MedEx 0.2.1. The release guide
  describes artifact preparation, qualification and publication.


## 0.1.0

- Compose two-way WebRTC talkback, independent diagnostic preview and recording, and manual pulse review in one exam.
- Commit clinical acceptance and its FHIR outbox intent atomically in PostgreSQL.
- Verify the Mix release with Chromium and native PostgreSQL and HAPI.
