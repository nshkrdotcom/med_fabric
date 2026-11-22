<p align="center"><img src="assets/web.svg" width="200" alt="Shared clinician and patient interface" /></p>

<h1 align="center">Shared clinician and patient interface</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

## Planned responsibility

Define reusable encounter workflow, clinical review, and observation acceptance views. Composes live WebRTC signaling hooks, WebAudio worklets, and signal integrity badges from `med_ex`'s `med_web` once built, while owning encounter routing, clinical authorization, and review acceptance controls.

## Direct workspace dependencies

[domain](../domain/README.md)

## First acceptance scenario

Reconnecting the clinician browser rejoins the existing `session_id` on a new `connection_id`, surfaces the live-preview interruption separately from recording continuity, and presents one deduplicated acquisition for review.

[Workspace plan](../../README.md)
