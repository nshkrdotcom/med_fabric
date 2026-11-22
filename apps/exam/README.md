<p align="center"><img src="assets/exam.svg" width="200" alt="Connected remote examination" /></p>

<h1 align="center">Connected remote examination</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_exam` (`apps/exam`) is the connected remote clinical examination application in [Med Fabric](../../README.md). It is the Phoenix + LiveView host app that consumes the single Welded `:med_ex` SDK and wires together `mf_domain`, `mf_store`, and `mf_interop`.

---

## What This Owns (and Does Not Own)

**`apps/exam` owns:**
- `MedFabric.Exam` (`start_session/3`, `ingest_effects/2`) — Direct composition between `MedFabric.Domain.Encounter` and `:med_ex` (`MedCore.Session`) with zero redundant forwarding wrappers.
- `MedFabric.ExamWeb.Endpoint` & `Router` — Phoenix/Bandit endpoint serving `/encounters/:encounter_id`, `/socket`, `/live`, and `/med_ex/session_hook.js` directly from `:med_ex`'s `MedWeb.Signaling.hook_asset_full_path/0`.
- `MedFabric.ExamWeb.UserSocket` & `SignalingChannel` — Authorizes every clinician connection against `encounter_ref`, relays WebRTC `sdp_offer`/`sdp_answer`/`ice_candidate` messages, and tracks reconnect `connection_id` transitions on the same `:med_ex` `MedRTC.SessionServer`.
- `MedFabric.ExamWeb.ExamLive` — Minimal exam LiveView mounting `phx-hook="MedExSessionHook"` inside `phx-update="ignore"` (preserving the peer connection across LiveView updates), separating preview status from recording continuity, and committing explicit clinician acceptance via `MedFabric.Store.OutboxStore`.

**`apps/exam` consumes from `:med_ex`:**
- Declared via `workspace_dep({:med_ex, github: "nshkrdotcom/med_ex", ref: "<projection/med_ex SHA>"})` with zero `override: true`. Standalone builds fetch the pinned private Git projection; Mix Workspace Ops `--mode local` points the exact same `:med_ex` OTP app at `../med_ex/dist/monolith/med_ex`.

---

## Walkthrough & Executable Tests

- `test/mf_exam_test.exs` — Full end-to-end pipeline: Welded `:med_ex` `session_hook.js` + `MedRTC.WavCapture` 4 kHz WAV replay + real `ExWebRTC` loopback disconnect/reconnect → redelivered `capture_completed` → `Encounter` single review candidate → explicit acceptance → atomic `OutboxStore` commit + post-commit lost-reply crash retry → `FhirClient` lost-HTTP-response conditional-create retry → single remote FHIR R4 `Observation` read-back.
- `test/mf_exam_web_test.exs` — Phoenix/LiveView/Channel proof: `GET /med_ex/session_hook.js` returns `200` with `RTCPeerConnection`; `SignalingChannel` enforces `encounter_ref` auth and relays SDP/ICE across `conn_a` → `conn_b` on one `session_id`; `ExamLive` preserves `phx-update="ignore"` `MedExSessionHook` across updates and commits clinician clicks into `OutboxStore`.

---

## Commands & Verification

```bash
cd apps/exam
mix deps.get
mix test
mix credo --strict
mix dialyzer --force-check
```

## Related Packages

- [Med Fabric Workspace](../../README.md)
- [Domain](../../core/domain/README.md)
- [Runtime](../../core/runtime/README.md)
- [Store](../../core/store/README.md)
- [Interop](../../core/interop/README.md)
- MedEx SDK: https://github.com/nshkrdotcom/med_ex
