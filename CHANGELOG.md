# Med Fabric changelog

## 0.2.0 (unreleased)

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
- Use the local MedEx 0.2 candidate until Hex publication. See the browser-to-record guide for the QC and release workflow.


## 0.1.0

- Compose two-way WebRTC talkback, independent diagnostic preview and recording, and manual pulse review in one exam.
- Commit clinical acceptance and its FHIR outbox intent atomically in PostgreSQL.
- Verify the Mix release with Chromium and native PostgreSQL and HAPI.
