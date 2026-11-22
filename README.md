<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

Med Fabric is an Elixir poncho for device-assisted remote clinical encounters. Each child owns an independent Mix project. The applications compose reusable libraries through local path dependencies for intra-repo packages and Mix Workspace Ops (`workspace_dep/1`) for cross-repository composition with `med_ex`.

## Package map

| Project | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Pure encounter decisions and consumer acceptance rules |
| [core/runtime](core/runtime/README.md) | Encounter supervision and durable effect dispatch |
| [core/store](core/store/README.md) | Clinical persistence, audit, and transactional outbox |
| [core/devices](core/devices/README.md) | Device capabilities and acquisition orchestration |
| [core/rtc](core/rtc/README.md) | Encounter-to-MedEx live session translation (`med_core` / `med_rtc` seam) |
| [core/media](core/media/README.md) | Clinical artifact provenance and recorded signal review indexing |
| [core/interop](core/interop/README.md) | Healthcare record exchange (single FHIR delivery plane) |
| [core/web](core/web/README.md) | Shared clinician and patient encounter workflow interface |
| [apps/exam](apps/exam/README.md) | Connected remote examination |
| [apps/steth](apps/steth/README.md) | Digital stethoscope composition example |

## Encounter flow

The product selects a clinical workflow and stream profile. The runtime passes commands to `mf_domain`, then persists decisions, events, and effect intents in `mf_store`. Live WebRTC sessions, Membrane media pipelines, lossless capture continuity, and signal integrity live in `med_ex` (`med_core` + `med_rtc`) and enter `med_fabric` through `mf_rtc`. An accepted observation and its FHIR export intent share one PostgreSQL transaction; failed FHIR delivery retries through `mf_interop` without losing the clinical record.

## Delivery sequence

1. Align encounter commands, events, four-level correlation IDs, and the canonical reconnect/duplicate-delivery contract between `med_core` and `mf_domain`.
2. Connect a simulated device and a real two-browser WebRTC call (via `med_ex`) to the `apps/exam` workflow. Exercise preview disconnect, capture completion, browser rejoin, duplicate notification deduplication, and export retry.
3. Expand validated stream profiles for guided auscultation and multi-sensor monitoring (`med_ex`'s `apps/med_pulse` and `apps/exam`).
4. Add multi-party transport and future `mf_interop` adapters (such as DICOM) only when a concrete product requires them.

## Workspace commands

Use Elixir 1.18 or later in the 1.x series. Run from the repository root.

```sh
mix deps.get
mix setup
mix test
mix quality
mix weld.verify
```

Blitz installs child dependencies with `mix setup`, fans out ExUnit with `mix test`, and runs strict Credo and Dialyzer with `mix quality`. Weld verifies an internal monolith rooted in both applications, including the selected projects’ baseline suites and the projected suite. Each child also supports ordinary Mix commands in its own directory.

## Composition with MedEx

MedEx and Med Fabric evolve as separate repositories with a strictly **one-way dependency direction (`med_fabric` → `med_ex`)** and one owner per responsibility:

| Responsibility | Owner | Contract |
| --- | --- | --- |
| Live session (`MedCore.Session`), stream specs, topology, preview vs. recording integrity | MedEx `med_core` | Products declare `MedCore.Profile` streams and consume producer integrity/capture facts. |
| WebRTC, Opus, SCTP, Membrane pipelines, lossless capture tees, peer recovery | MedEx `med_rtc` | `mf_rtc` translates encounter permissions, correlation IDs, and effect intents into `med_rtc` and forwards facts back to `mf_runtime`. |
| Browser tracks, signaling hooks, WebAudio worklets, connection & integrity badges | MedEx `med_web` | `mf_web` supplies encounter workflow, clinical review views, and authorization. |
| Real-time signal/AI compute & external media planes (Ortex/ONNX, NeuroKit2/WFDB, LiveKit, Pipecat) | MedEx `med_adapters` | Selected declaratively by product profiles; outputs carry SaMD advisory metadata gated on validated integrity. |
| Durable encounter lifecycle, observation acceptance, transactional outbox, FHIR delivery | Med Fabric `mf_domain`, `mf_runtime`, `mf_store`, `mf_devices`, `mf_interop` | Persist accepted observations and FHIR export intents in one transaction. DICOM export remains deferred until needed. |
| Recorded artifact provenance & clinical review indexing | Med Fabric `mf_media` | Associates finalized capture hashes/URIs and `med_ex` integrity reports with clinical acquisitions and clinician reviews. Does not run Membrane pipelines. |
| End-user products | Med Fabric `apps/exam` and MedEx `apps/med_pulse` | Keep `apps/steth` as a lightweight composition example while standalone stethoscope/RPM work lives in `med_ex`'s `apps/med_pulse`. |

### Four-Level Identity & Integrity Model

| Identifier | Owner | Lifetime |
| --- | --- | --- |
| `encounter_ref` *(optional)* | Med Fabric `mf_domain` | Durable clinical episode spanning sessions, acquisitions, and reconnects. Omitted for standalone `med_ex` captures. |
| `session_id` | MedEx `med_core` | Live real-time session. Outlasts individual browser WebRTC disconnects. |
| `connection_id` | MedEx `med_rtc` | Individual WebRTC peer-connection attempt within a `session_id`. |
| `acquisition_id` | Device capture span | Lossless recording or sensor capture; valid even without an active clinician preview or `encounter_ref`. |

Live preview continuity (`{:preview_stream, stream_id}`) and device recording continuity (`{:recording_artifact, acquisition_id}`) are reported independently with explicit intervals and epistemic status (`:observed_continuous | :observed_gap | :unknown`). See the producer trace in `med_ex`'s `core/med_core/README.md` and the paired consumer acceptance rules in [core/domain/README.md](core/domain/README.md).

### Mix Workspace Ops & Cross-Repository Dependency Wiring

- Intra-repo dependencies in `med_fabric` stay ordinary relative `path:` tuples (`{:mf_domain, path: "../domain"}`).
- Cross-repo dependencies into `med_ex` (starting with `core/rtc/mix.exs` → `:med_core` and `:med_rtc`) load `MIX_WORKSPACE_OPS_BOOTSTRAP` when set and wrap committed pinned private GitHub tuples with `workspace_dep/1`:
  - **Standalone / CI checkout**: resolves directly from pinned private GitHub `nshkrdotcom/med_ex` (`subdir: "core/med_core"` / `"core/med_rtc"`) with `:med_core` converged to a single copy (`override: true`).
  - **Local multi-repo development**: Mix Workspace Ops overrides `:med_core` and `:med_rtc` via a private operator registry/view (`~/.config/mix_workspace_ops/medical/`) to verified local sibling checkouts (`../med_ex/core/med_core`, `../med_ex/core/med_rtc`), keeping private repository metadata out of the public `portfolio_registry`.
