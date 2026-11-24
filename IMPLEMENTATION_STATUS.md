# Implementation status

Med Fabric 0.2.0 implements the simulated paired acoustic/ECG examination and
PLXS pulse-oximeter spot check. The Exam server owns authorization, capture
manifests, review, derived metrics and the FHIR outbox. The standalone handheld
uses CA-verified WSS and a durable spool. The optional preview runs in a
separate BEAM.

## Runtime qualification

- Elixir 1.20.5 and OTP 29.1.2 compiled the headless and native projects.
  PostgreSQL 18.6 passed fresh migrations and repeated migration of a prior
  schema with ready, recording, interrupted and accepted outbox records.
- Both paired process suites passed. They verified independent PCM oracles,
  source gaps and resets, rational-rate s24, bounded spooling, writer stalls,
  fenced replay, server crash recovery and abrupt handheld restart. During
  restart, a competing handheld was refused and only synchronized source
  records were replayed. Immutable review retries and staged manifest byte
  equality passed.
- The isolated preview suite received real browser RTC audio, killed the preview
  BEAM and observed the viewer disconnect while authoritative capture continued.
  The review browser exercised WAV playback, ECG SVG inspection and alignment
  and gap disclosure. The separate legacy browser suite passed.
- The spot-check suite passed on HAPI FHIR R4 7.6.0. It verified synchronized
  event replay, unusable and repeated measurements, atomic metric acceptance,
  two remote Observations and exact read-back after a lost upstream reply.
- Verified MedEx revisions and optional provider subdirectories are pinned in
  the Mix locks. The plain Mix default remains headless. The source-selection
  checks covered separate mutable paths, legacy Hex 0.1.0 and the explicit
  missing stream-v1 diagnostic.

See the [handheld runbook](guides/handheld_demo.md) for the commands and
deployment ownership requirements. The Python runner and fault proxy drive
the retained real-network tests.

## Physical device and clinical validation

Qualification still requires real ADC and oscillator measurements, channel
calibration and units, hardware dropout and restart behavior, BLE conformance,
target deployment security, clinician human factors, and evidence supporting
the specific intended clinical use.
