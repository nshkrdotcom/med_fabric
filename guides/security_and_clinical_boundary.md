# Security and Clinical Boundary

## 1. Authentication and Authorization Model

- **Clinician / Patient encounter routes (`mf_exam` HTTP):** Scoped by
  encounter ID and role. Local HTTP uses distinct role-specific access keys
  (`?key=<clinician_key>`); public HTTPS requires the configured authenticating
  loopback reverse proxy and proxy secret. Bare `/` is not served. Role
  separation prevents patient sessions from committing clinical acceptance or
  triggering FHIR export.
- **Device ingress (`mf_exam` HTTPS/WSS):** Authenticated TLS WebSocket
  listener using the lab/deployment CA and enrolled device credentials. Only
  enrolled devices admitted to an active encounter and profile may push frames.
- **Preview sidecar (`mf_preview`):** Authenticated with a nonempty shared
  Preview credential. Deployment must isolate it in a separate BEAM OS process;
  adding both packages as runtime dependencies of one host starts them together.

## 2. PHI-Free Diagnostics

- Logs, telemetry metadata, and error reports must carry only opaque IDs
  (encounter ID, acquisition ID, stream ID, SHA-256 digests), never patient
  demographics or raw clinical notes.
- `erl_crash.dump` is ignored in `.gitignore` and must never be committed or
  shipped in release artifacts.

This is a diagnostics policy, not a claim that BEAM crash dumps are scrubbed.
A crash dump can contain process state and secrets; keep it outside release
artifacts and ordinary log collection. A complete PHI/logging audit remains open.

## 3. Synthetic vs. Clinical Qualification Scope

- **Previously exercised with synthetic fixtures:** Paired acoustic/ECG capture, sparse PLXS spot
  checks, 29-minute ext4 soak, TLS reconnect/replay, and HAPI FHIR R4 retry
  read-back.
- **Current release gate:** Re-run those suites, including the 29-minute ext4
  soak, against the exact 0.3.0 SDK and 0.2.0 application/provider candidates.
- **Not clinically qualified:** Physical peripheral timing, hardware
  calibration, regulatory device clearance, and production clinical deployment
  require separate qualification outside this repository.
