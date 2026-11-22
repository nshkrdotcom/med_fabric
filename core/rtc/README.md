<p align="center"><img src="assets/rtc.svg" width="200" alt="Encounter-to-MedEx live session bridge" /></p>

<h1 align="center">Encounter-to-MedEx live session bridge</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Bridge Med Fabric's encounter permissions, correlation IDs (`encounter_ref`, `acquisition_id`), and effect intents into MedEx's live transport runtime (`med_core` and `med_rtc`). Translates `med_ex` producer facts (`peer_connection_changed`, `integrity_reported`, `capture_completed`) back into `mf_runtime` inputs without duplicating WebRTC, Opus, SCTP, or Membrane implementation.

Keep this adapter thin—it exists only to own the encounter-to-session authorization and correlation translation.

## Direct dependencies

- Workspace: [domain](../domain/README.md)
- Cross-repository (`workspace_dep/1`): `med_ex` (`:med_core`, `:med_rtc`)

## First acceptance scenario

Revoking an encounter participant terminates their authorized `med_rtc` connections, while a transient browser drop on `connection_id` preserves the active `session_id` and device `acquisition_id`.

[Workspace plan](../../README.md)
