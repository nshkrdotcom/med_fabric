<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`Med Fabric` is an Elixir poncho for durable remote clinical encounters, atomic clinician observation acceptance, and HL7 FHIR R4 delivery. It consumes the single Welded `:med_ex` SDK one-way (`med_fabric` → `:med_ex`) so live WebRTC transport and recording integrity stay decoupled from clinical workflow state.

---

## What This Owns (and Does Not Own)

**`med_fabric` owns:**
- Durable clinical encounter state, review candidates, digest-conflict blocking, and explicit clinician acceptance (`core/domain` — `MedFabric.Domain.Encounter`).
- Encounter runtime boundary (`core/runtime` — intentionally minimal until multi-process workflow coordination requires a long-lived encounter supervisor).
- Atomic acceptance + recording provenance + transactional FHIR export outbox persistence (`core/store` — `MedFabric.Store.OutboxStore` + reference PostgreSQL 17 DDL).
- Single authoritative HL7 FHIR R4 `Observation` projection and idempotent conditional-create (`If-None-Exist`) client (`core/interop` — `MedFabric.Interop.FhirClient`).
- The Phoenix + LiveView clinical exam application (`apps/exam` — `MedFabric.Exam`, `MedFabric.ExamWeb.Endpoint`, `UserSocket`, `SignalingChannel`, `Router`, `ExamLive`).

**`med_fabric` does not own:**
- Live WebRTC sessions (`MedCore.Session`), ExWebRTC peer transport (`MedRTC`), PCM WAV replay (`MedRTC.WavCapture`), or the browser `RTCPeerConnection` JavaScript hook (`session_hook.js`). Those come from the single `:med_ex` SDK (`https://github.com/nshkrdotcom/med_ex`, branch `projection/med_ex`).

---

## Package Map

| Package | Path | Implemented Today | Documentation |
| --- | --- | --- | --- |
| **Domain** | `core/domain` | Pure `MedFabric.Domain.Encounter` reducer + 3 tests | [core/domain/README.md](core/domain/README.md) |
| **Runtime** | `core/runtime` | Thin boundary module (no speculative supervision yet) | [core/runtime/README.md](core/runtime/README.md) |
| **Store** | `core/store` | `MedFabric.Store.OutboxStore`, Postgres 17 DDL, 3 crash-recovery tests | [core/store/README.md](core/store/README.md) |
| **Interop** | `core/interop` | `MedFabric.Interop.FhirClient` (`Req`), lost-response conditional-create retry test | [core/interop/README.md](core/interop/README.md) |
| **Exam** | `apps/exam` | `MedFabric.Exam`, Phoenix `Endpoint`, `SignalingChannel`, `ExamLive`, 4 end-to-end tests | [apps/exam/README.md](apps/exam/README.md) |

---

## Browser & WebRTC Boundary (`apps/exam` vs. `:med_ex`)

| Decision | Owner & Contract |
| --- | --- |
| **Phoenix endpoint, routes, signaling channel, LiveViews** | `med_fabric/apps/exam` (`apps/exam/mix.exs`). No second Phoenix app is needed. |
| **Browser `RTCPeerConnection` JS hook & media peer API** | `:med_ex` (`MedWeb.Signaling.hook_asset_full_path/0` served by `ExamWeb.Endpoint` at `/med_ex/session_hook.js`). |
| **First browser media topology** | MedEx server → clinician browser for live instrument preview. Two-way patient talkback is a separate media path decided when added. |
| **Reconnect survival** | LiveView updates preserve the JS hook inside `phx-update="ignore"`. Browser reloads create a new `connection_id` under the same `session_id`; `SignalingChannel` re-authorizes against `encounter_ref` while capture continues independently. |

---

## Walkthrough: Full End-to-End Slice

Trace the complete flow in `apps/exam/test/mf_exam_test.exs` and `apps/exam/test/mf_exam_web_test.exs`:

1. **Live capture + WebRTC preview drop**: Replay a 4 kHz PCM WAV via `:med_ex`'s `MedRTC.WavCapture` while tearing down an `ExWebRTC` loopback peer (`conn_a`) mid-capture and reconnecting on `conn_b`.
2. **Idempotent ingestion**: Feed `:med_ex`'s emitted `capture_completed` fact twice into `MedFabric.Exam.ingest_effects/2` → `MedFabric.Domain.Encounter` keeps one `:ready_for_review` candidate with `:observed_continuous` while recording the preview interruption separately as transient state.
3. **Phoenix + LiveView + Signaling**: `ExamWeb.Endpoint` serves `/med_ex/session_hook.js`, `SignalingChannel` rejects unauthorized encounters and relays SDP/ICE across `conn_a` → `conn_b`, and `ExamLive` preserves `phx-hook="MedExSessionHook"` (`phx-update="ignore"`) while handling explicit clinician acceptance.
4. **Atomic persistence + crash recovery**: `OutboxStore.commit_acceptance/4` commits `{observation, provenance, outbox}` atomically; retrying after a pre-commit failure or post-commit lost reply converges on 1 observation and 1 export intent.
5. **Idempotent FHIR R4 delivery**: `FhirClient.deliver/2` drops the first HTTP response after remote write, retries with `If-None-Exist` on the stable business identifier, and reads back exactly 1 remote FHIR R4 `Observation`.

---

## Commands & Verification

Toolchain pins live in `.tool-versions` (`erlang 29.1.2`, `elixir 1.20.5-otp-29`). All ordinary Mix, Blitz, and Weld checks run completely offline with zero Docker containers.

```bash
# Parallel workspace checks via Blitz
mix deps.get
mix setup
mix test
mix quality
mix weld.inspect
mix weld.verify

# Optional local services (PostgreSQL 17, HAPI FHIR R4 v7.6.0, optional coturn under --profile turn)
docker compose -f ops/compose.yml up -d
```

## Upstream Ecosystem

- MedEx SDK: https://github.com/nshkrdotcom/med_ex
- Blitz: https://github.com/nshkrdotcom/blitz
- Weld: https://github.com/nshkrdotcom/weld
- Phoenix Framework: https://github.com/phoenixframework/phoenix
- Phoenix LiveView: https://github.com/phoenixframework/phoenix_live_view
- Req: https://github.com/wojtekmach/req
- HAPI FHIR: https://github.com/hapifhir/hapi-fhir-jpaserver-starter

## License

MIT — see [LICENSE](LICENSE).
