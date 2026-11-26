# Security and Clinical Boundary

## 1. Authentication and Authorization Model

- **Clinician / Patient encounter routes (`mf_exam` HTTP):** Scoped by
  encounter ID and role-specific key (`?key=<clinician_key>`). Bare `/` is not
  served. Role separation prevents patient sessions from committing clinical
  acceptance or triggering FHIR export.
- **Device ingress (`mf_exam` HTTPS/WSS):** Authenticated TLS WebSocket
  listener using the lab/deployment CA and enrolled device credentials. Only
  enrolled devices admitted to an active encounter and profile may push frames.
- **Preview sidecar (`mf_preview`):** Authenticated with a shared Preview
  credential and isolated in a separate BEAM OS process.

## 2. PHI-Free Diagnostics

- Logs, telemetry metadata, and error reports must carry only opaque IDs
  (encounter ID, acquisition ID, stream ID, SHA-256 digests), never patient
  demographics or raw clinical notes.
- `erl_crash.dump` is ignored in `.gitignore` and must never be committed or
  shipped in release artifacts.

## 3. Synthetic vs. Clinical Qualification Scope

- **Qualified as synthetic:** Paired acoustic/ECG capture, sparse PLXS spot
  checks, 29-minute ext4 soak, TLS reconnect/replay, and HAPI FHIR R4 retry
  read-back.
- **Not clinically qualified:** Physical peripheral timing, hardware
  calibration, regulatory device clearance, and production clinical deployment
  require separate qualification outside this repository.
