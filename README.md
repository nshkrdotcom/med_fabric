<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`Med Fabric` is an Elixir poncho for durable remote clinical encounters, atomic clinician observation acceptance, and HL7 FHIR R4 delivery. The exam uses one Welded `:med_ex` SDK for WebRTC preview and recording.

---

## Projects

| Path | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Bind acquisition facts and decide explicit acceptance in pure Elixir |
| [core/store](core/store/README.md) | Commit acceptance, provenance, and outbox in one PostgreSQL transaction |
| [core/interop](core/interop/README.md) | Deliver and confirm one reviewed observation over FHIR R4 |
| [apps/exam](apps/exam/README.md) | Boot Phoenix, authorize the lab, and host the review and delivery UI |

Follow the [native browser-to-record runbook](docs/architecture/browser-to-record.md) for Ubuntu 26.04 onboarding, diagrams, focused tests, and the listening check.
