# Architecture refinement

The connected exam consumes one projected `:med_ex` SDK (`projection/med_ex` in Git/CI, `dist/monolith/med_ex` locally via Mix Workspace Ops). MedEx owns live peer state, WebRTC transport, browser hook assets, and measured capture facts. `MedFabric.Exam` translates those facts directly into `MedFabric.Domain.Encounter` transitions with no intermediate forwarding module. Med Fabric owns review candidates, conflict blocking, and explicit clinical acceptance.

| State | Authority | Recovery |
| --- | --- | --- |
| Peer connection and current preview | `ExWebRTC.PeerConnection` + `MedRTC.SessionServer` | Rejoin with a new `connection_id`. Late disconnects from a replaced `connection_id` are ignored without interrupting the new connection. |
| Recording identity and measured continuity | `MedCore.Session` (`integrity_reports`) | Single authoritative continuity map (`:observed_continuous \| :observed_gap \| :unknown`). Redelivery preserves the original digest; conflicting digests enter sticky `:conflict`. |
| Requested acquisition, review candidate, acceptance | `MedFabric.Domain.Encounter` | Pure functional model. Duplicate completion yields one review candidate; `:conflict` blocks acceptance; explicit acceptance returns pure `%{observation, export_intent}` idempotently. |
| Projection source identity | `mix med_ex.projection.refresh` / `status --strict` | Computes pre/post SHA-256 fingerprint across Weld roots, lockfiles, assets, and Weld/Elixir versions before local consumer checks. |

## Checkpoints

- [x] Verify source tests, SDK projection (`3ac1df64`), and exam dependency identity in both local MWO projection and clean GitHub checkout modes.
- [x] Correct ownership bugs in `MedCore.Session`: ignore late disconnects from replaced connections, keep `:conflict` sticky across redelivery, remove duplicate `integrity_state` map and unused `degradation_level` field, and delete dead version probes (`MedRTC.core_version/0`, `MedWeb.runtime_core_version/0`, `MedAdapters.core_version/0`).
- [x] Fold redundant `MedFabric.Exam.SessionBridge` directly into `MedFabric.Exam` so one module owns encounter-to-SDK session creation and fact ingestion.
- [x] Verify real `ExWebRTC 0.18.0` SDP/ICE loopback reconnect + shipped `priv/static/med_web/session_hook.js` (`node --check` + Weld packaging check) + `MedFabric.Domain.Encounter` single-candidate review and acceptance against both local Welded projection and pinned `projection/med_ex`.
- [ ] Prove two real browser tabs exchanging live WebRTC audio through `session_hook.js` during simulated capture + tab reconnect (requires desktop/Chromium browser harness; not installed on headless build host).

## Architecture Review Conclusions

- **Processes kept**: `ExWebRTC.PeerConnection` (library-owned transport) and `MedRTC.SessionServer` (single session coordinator). `mf_runtime` stays passive until durable commit-and-retry gives it real execution/recovery behavior.
- **What Weld caught beyond source checks**:
  1. `MedWeb.Signaling.hook_asset_full_path/0` had to resolve via `Application.get_application(__MODULE__)` so `priv/static/med_web/session_hook.js` resolves under `:med_web` in source mode and under `:med_ex` inside the Welded monolith.
  2. `MedFabric.ExamTest` confirmed that the projected `:med_ex` package ships `ex_webrtc`, compiles its native DTLS/SRTP deps cleanly in a clean checkout, and exposes the JS hook asset alongside `MedCore`/`MedRTC`/`MedWeb` modules.
- **Next gated constraints (one at a time)**:
  1. Durable clinical acceptance (`mf_store` atomic commit of observation + outbox intent + crash-before/after-commit retry test, earning `mf_runtime` recovery).
  2. One real hardware/fixture device capture path.
  3. One real FHIR R4 export + failure/retry test against a test endpoint.
