<p align="center"><img src="assets/domain.svg" width="200" alt="Pure encounter decisions" /></p>

<h1 align="center">Pure encounter decisions</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_domain` (`core/domain`) provides pure Elixir clinical evidence constructors
for [Med Fabric](../../README.md), with zero database, Phoenix, or HTTP
dependencies.

---

## Domain rules

`MedFabric.Domain.Evidence` validates finalized `audio_pcm16_wav` recording
evidence (48 kHz mono digests, sample count, continuity, and browser capture
provenance) and operator-entered `pulse_rate` measurements (positive integer
beats/minute with explicit manual provenance). PostgreSQL (`core/store`) owns
concurrent review and acceptance state.

Run `mix test` here, or see the [browser-to-record guide](../../guides/browser_to_record.md).
