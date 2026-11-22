<p align="center"><img src="assets/runtime.svg" width="200" alt="Encounter supervision and effect dispatch" /></p>

<h1 align="center">Encounter supervision and effect dispatch</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Supervise one workflow per active encounter. Load durable history on restart, pass commands to the domain and hand committed intents to interpreters. Keep retry identifiers stable across restarts.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

Recover an interrupted acquisition from committed events and reconcile outstanding effects.

[Workspace plan](../../README.md)
