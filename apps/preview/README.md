<p align="center">
  <img src="https://raw.githubusercontent.com/nshkrdotcom/med_fabric/main/apps/preview/assets/preview.svg" alt="Med Fabric Preview logo" width="200" />
</p>

# Med Fabric Preview

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric/tree/main/apps/preview"><img src="https://img.shields.io/badge/GitHub-mf__preview-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/apps/preview/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_preview` 0.3.0 is an optional, disposable monitoring service in its own BEAM
OS process. It composes `med_ex_opus ~> 0.3.0` and `med_ex_rtc ~> 0.3.0` directly,
using `med_ex ~> 0.4.0` only for technical wire/contracts. It has no database,
clinical decision, source spool or recording authority.

## Runtime

A validated explicit configuration starts a loopback Bandit listener, registry,
a bounded feed owner and temporary media peers. Each viewer peer owns one
concrete Opus encoder and one opaque concrete RTC handle. Encoder completion is
matched by a unique bounded operation ID and source sample; RTC notifications
are matched through the provider's peer-reference accessor. Replacement closes
old resources and resets media origins. Failed or abandoned peers never restart
automatically.

Exam authorizes eligible paired-device or browser-microphone monitoring. It
signs a purpose/source/generation/descriptor/viewer/session-bound capability
with a maximum 25-second lifetime. Preview requires a verified relative clock
error of at most two seconds and conservatively subtracts it from the local
monotonic deadline. Feed activity and status requests do not renew authority.
A new Exam authorization is required for `POST /renew`.

Preview rechecks authority before negotiation, feed, encoding and sending. RTC
receives the same local deadline and checks it at actual submission. No new
packet is submitted after that deadline; an already emitted network packet
cannot be recalled. Clock discontinuity or a lost renewal closes media.

See [Getting started](guides/getting_started.md) for configuration and
[Isolation model](guides/isolation_model.md) for precise resource, transport and
failure boundaries. Build/package this application directly with Mix. Its real
native encoder/receiver tests require the pinned native dependencies and local
WebRTC; unit tests alone do not qualify separate-process failure isolation or
relay-only TURN.

**License:** [MIT](LICENSE).
