<p align="center"><img src="assets/exam.svg" width="200" alt="Connected remote examination" /></p>

<h1 align="center">Connected remote examination</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

First complete clinical product application in Med Fabric. Composes `mf_runtime`, `mf_store`, `mf_interop`, and the single `:med_ex` SDK (`workspace_dep/1`) to:

- authorize encounter participants and declare product stream profiles;
- bridge encounter correlation IDs (`encounter_ref`, `acquisition_id`) onto `:med_ex` via `MedFabric.Exam.SessionBridge`;
- coordinate simulated and real device acquisitions, link finalized recording artifacts and continuity verdicts into clinical review; and
- commit clinician-accepted observations together with their FHIR export intent in one `mf_store` transaction before `mf_interop` dispatches delivery.

## Direct dependencies

- Workspace: [runtime](../../core/runtime/README.md), [store](../../core/store/README.md), [interop](../../core/interop/README.md)
- Cross-repository (`workspace_dep/1`): `:med_ex` (pinned to private Git projection `projection/med_ex`, or local Welded projection `dist/monolith/med_ex` via Mix Workspace Ops)

## First acceptance scenarios

1. **Reconnect & duplicate capture completion**: Establish a two-browser WebRTC call with a deterministic simulated capture. Drop the clinician's live preview (`connection_id: "conn_a"`) while capture completes independently on the device. Rejoin the browser (`connection_id: "conn_b"`), deliver `capture_completed` twice, and verify the clinician sees the preview interruption separately from the recording's independently reported continuity and sees one deduplicated acquisition ready for review.
2. **Review, acceptance & retried FHIR export**: Clinician reviews the finalized recording artifact and its continuity evidence, explicitly accepts the observation, commits observation + outbox intent in one transaction, and retries FHIR delivery after an endpoint failure without duplicating the record.

[Workspace plan](../../README.md)
