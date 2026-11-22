<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

Med Fabric is an Elixir poncho for device-assisted remote clinical encounters and production clinical applications. Each child owns an independent Mix project enforcing concrete dependency and test-loop boundaries.

## Package map

| Project | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Pure encounter decisions and consumer acceptance rules (zero workspace deps) |
| [core/runtime](core/runtime/README.md) | Encounter supervision and durable effect dispatch (zero DB/Phoenix deps) |
| [core/store](core/store/README.md) | Clinical persistence, artifact provenance refs, audit, and transactional outbox |
| [core/interop](core/interop/README.md) | Single authoritative HL7 FHIR delivery and outbox retry plane (DICOM deferred) |
| [apps/exam](apps/exam/README.md) | Connected remote examination product composing Med Fabric workflows with the single `:med_ex` SDK |

## Encounter flow

`apps/exam` selects the clinical workflow and stream profile, authorizes live participants, and bridges encounter state onto `:med_ex` (`MedFabric.Exam.SessionBridge`). `mf_runtime` passes commands to `mf_domain` and persists decisions, events, and effect intents in `mf_store`. Live WebRTC sessions, Membrane pipelines, lossless capture continuity, and browser media hooks come from the single `:med_ex` SDK. An accepted observation and its FHIR export intent share one PostgreSQL transaction; failed FHIR delivery retries through `mf_interop` without losing the clinical record.

## Delivery sequence

1. Prove one `:med_ex` SDK app identity from both a locally generated projection (via Mix Workspace Ops) and a clean checkout pinned to private Git branch `projection/med_ex`.
2. Exercise the first real vertical slice in `apps/exam`: two-browser WebRTC talkback + deterministic simulated capture + clinician preview disconnect/rejoin + duplicate `capture_completed` delivery → clinician sees preview interruption separately from recording continuity and accepts one deduplicated observation with a retried FHIR export.
3. Extract shared packages (such as a standalone session bridge, device catalog, review UI, or a separate stethoscope app) only when a second real clinical product shares them.

## Workspace commands

Use Elixir 1.18 or later in the 1.x series. Run from the repository root.

```sh
mix deps.get
mix setup
mix test
mix quality
mix weld.inspect
mix weld.verify
```

Blitz runs child tasks in parallel (`multiplier: :auto`). `apps/exam` deploys as a standard Mix release; Weld (`build_support/weld.exs`) keeps the reusable clinical workflow core (`core/domain`, `core/runtime`, `core/store`, `core/interop`) verified cleanly without flattening deployable products or duplicating `:med_ex` pins.

## Composition with MedEx (`:med_ex`)

MedEx and Med Fabric evolve as separate repositories with a strictly **one-way dependency direction (`med_fabric` → `:med_ex`)** and one owner per responsibility:

| Responsibility | Owner | Contract |
| --- | --- | --- |
| Live session (`MedCore.Session`), stream specs, preview vs. recording integrity, WebRTC/Opus/Membrane transport, lossless capture tees, browser signaling & WebAudio hooks | MedEx (`:med_ex` Welded browser-capable SDK) | Consumed as **one OTP app (`:med_ex`)** by `apps/exam` with zero `override: true` and identical app identity in local MWO and clean GitHub checkouts. |
| Durable encounter lifecycle, observation acceptance, transactional outbox, recording provenance refs, FHIR delivery | Med Fabric (`mf_domain`, `mf_runtime`, `mf_store`, `mf_interop`) | Persist accepted observations and FHIR export intents in one transaction. Single FHIR delivery implementation across both repos. |
| Production clinical screens, encounter-to-session bridge, device request coordination, recording review | Med Fabric (`apps/exam`) | Hosts the first `SessionBridge`, review UI, and preview-drop recording-review acceptance scenario. |

### Four-Level Identity & Integrity Model

| Identifier | Owner | Lifetime |
| --- | --- | --- |
| `encounter_ref` *(optional)* | Med Fabric `mf_domain` | Durable clinical episode spanning sessions, acquisitions, and reconnects. |
| `session_id` | MedEx `MedCore.Session` | Live real-time session. Outlasts individual browser WebRTC disconnects. |
| `connection_id` | MedEx `MedRTC` | Individual WebRTC peer-connection attempt within a `session_id`. |
| `acquisition_id` | Device capture span | Lossless recording or sensor capture; valid even without an active clinician preview or `encounter_ref`. |

See the producer trace in `med_ex`'s `core/med_core/README.md` and the paired consumer acceptance rules in [core/domain/README.md](core/domain/README.md).
