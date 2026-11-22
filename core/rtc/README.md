<p align="center"><img src="assets/rtc.svg" width="200" alt="Session signaling and transport" /></p>

<h1 align="center">Session signaling and transport</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Translate transport plans into peer sessions. Start with one-to-one WebRTC, Opus and TURN fallback. Keep stream authorization tied to encounter membership and expose connection state to the runtime.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

Revoking a participant ends their authorized streams.

[Workspace plan](../../README.md)
