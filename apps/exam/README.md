<p align="center"><img src="assets/exam.svg" width="200" alt="Connected remote examination" /></p>

<h1 align="center">Connected remote examination</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/apps/exam/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_exam` (`apps/exam`) is the deployable Phoenix + LiveView reference
examination application in [Med Fabric](../../README.md). It consumes the single
source [`:med_ex`](https://github.com/nshkrdotcom/med_ex) SDK and composes
`mf_domain`, `mf_store`, and `mf_interop`.

## Handheld examination

Exam checks the device credential and encounter grant before admitting a
stream or spot-check collection. It receives replay over TLS, persists
authoritative evidence and progress, and presents verified waveform segments,
gaps, timing bounds, and qualified measurements for review. PostgreSQL
commits acceptance and any FHIR delivery intent together. Run the default
Exam alongside the standalone Handheld client using the
[handheld guide](../../guides/handheld_demo.md). The
[isolated Preview service](../../guides/preview_isolation.md) is optional.
The default Exam compiles against the base MedEx SDK. Select
`MF_EXAM_LEGACY_MEDIA=1` for the native browser providers and resolve,
build, and run that profile in its independent Mix context.


## Browser-to-record path

The Phoenix app starts its own endpoint, PubSub, PostgreSQL connection, schema
migration, and capture supervisor when `MF_LAB=1` is configured. Patient and
clinician browsers negotiate a direct two-way WebRTC talkback call. An
independent authorized channel negotiates the clinician's receive-only
diagnostic preview peer while the patient browser streams live 48 kHz mono
PCM16LE over the encounter-scoped recording WebSocket. MedEx finalizes the lossless WAV independently of preview,
and the clinician reviews that recording alongside manually entered pulse-rate
measurements. PostgreSQL commits acceptance and export intent atomically, and an
async delivery action confirms each `Observation` against the FHIR R4 server.

See the [browser-to-record guide](../../guides/browser_to_record.md) for
prerequisites, Mix release startup, automated verification, and the listening
check.
