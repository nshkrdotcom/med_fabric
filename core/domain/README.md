<p align="center"><img src="assets/domain.svg" width="200" alt="Pure encounter decisions" /></p>

<h1 align="center">Pure encounter decisions</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Accept commands against durable clinical `Encounter` state and emit events and effect intents. Record the operator, device identity, units, acquisition time, provenance, and clinician review decisions on each observation. Replay must reproduce the exact same state.

`mf_domain` owns the **durable clinical encounter** (`encounter_ref`). Live transport sessions (`session_id`), WebRTC peer connections (`connection_id`), and raw stream/capture integrity evidence are produced by `med_ex`'s `MedCore.Session` and correlated here by `(encounter_ref, session_id, acquisition_id)`.

## Consumer acceptance rules (paired with `med_core` worked trace)

Paired with the canonical producer event trace in `med_ex`'s `core/med_core/README.md` (*clinician loses preview → device finishes recording → browser rejoins session → capture-complete arrives twice*):

1. **Encounter survives peer disconnects**: A `:peer_connection_changed` (`:disconnected`) fact on `connection_id: "conn_a"` updates transient live-presence projection only; it MUST NOT abort an active `acquisition_id` or close the `Encounter`.
2. **Preview vs. recording integrity remain distinct**: A preview interruption (`{:preview_stream, stream_id}`) is displayed as a live-monitoring notice and MUST NOT taint or overwrite an independently verified `{:recording_artifact, acquisition_id}` continuity report (`:observed_continuous`, `:observed_gap`, or `:unknown`).
3. **Idempotent capture ingestion**: Receiving `capture_completed` twice with the same `(acquisition_id, artifact_sha256)` produces **one** reviewable acquisition candidate (no duplicate observations or outbox entries). Receiving a conflicting `artifact_sha256` for an already completed `acquisition_id` raises a clinical conflict anomaly and blocks automatic acceptance.
4. **Explicit clinical acceptance boundary**: A `capture_completed` fact makes an acquisition *available for review*, never automatically accepted. Transitioning to an accepted `Observation` (and committing its FHIR export intent in `mf_store`) requires an explicit authorized clinician decision referencing the exact `artifact_sha256` and recording continuity status.

## Direct workspace dependencies

None. Domain decisions use only pure Elixir data.

## First acceptance scenario

A closed encounter rejects new acquisitions. Replaying the canonical reconnect trace with duplicate `capture_completed` delivery yields one reviewable acquisition whose recording continuity is preserved despite the preview interruption, and accepting it yields one observation.

[Workspace plan](../../README.md)
