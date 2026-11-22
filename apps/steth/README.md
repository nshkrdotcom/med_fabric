<p align="center"><img src="assets/steth.svg" width="200" alt="Digital stethoscope composition example" /></p>

<h1 align="center">Digital stethoscope composition example</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Lightweight composition example showing how an encounter workflow consumes guided auscultation (live preview + independent lossless capture from `med_ex`) and attaches recording position, continuity verdicts, and clinician annotations via `mf_media` and `mf_store`. Standalone digital stethoscope + RPM product work lives in `med_ex`'s `apps/med_pulse`.

## Direct workspace dependencies

[runtime](../../core/runtime/README.md), [store](../../core/store/README.md), [devices](../../core/devices/README.md), [rtc](../../core/rtc/README.md), [media](../../core/media/README.md), [web](../../core/web/README.md)

## First acceptance scenario

Interrupt the live preview during guided auscultation and verify that the finalized recording artifact retains its own continuity record in `mf_media` for clinician review.

[Workspace plan](../../README.md)
