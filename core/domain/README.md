<p align="center"><img src="assets/domain.svg" width="200" alt="Pure encounter decisions" /></p>

<h1 align="center">Pure encounter decisions</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Accept commands against encounter state and emit events and effect intents. Record the operator, device identity, units, acquisition time and signal profile on each observation. Replay must reproduce the same state.

## Direct workspace dependencies

None. Domain decisions use only Elixir data.

## First acceptance scenario

A closed encounter rejects new acquisitions. Retrying an accepted acquisition yields one observation.

[Workspace plan](../../README.md)
