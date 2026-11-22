<p align="center"><img src="assets/media.svg" width="200" alt="Clinical artifact provenance and review" /></p>

<h1 align="center">Clinical artifact provenance and review</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Index finalized recording artifacts and attach clinical provenance—storage URI, `artifact_sha256`, anatomical position, clinician annotations, and the independently measured `{:recording_artifact, acquisition_id}` integrity report produced by `med_ex`—to encounters and observations for clinician review.

Live media pipelines, Membrane elements, lossless WAV capture tees, and real-time sample/packet continuity checks live in `med_ex` (`med_core` and `med_rtc`), not here.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

Attach a finalized `med_ex` recording artifact and its continuity report to an encounter acquisition, keeping its integrity record distinct from any live-preview interruption during clinician review.

[Workspace plan](../../README.md)
