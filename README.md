<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

Med Fabric is an Elixir poncho for device-assisted remote encounters. Each child owns an independent Mix project. The two applications compose reusable libraries through local path dependencies. This initial revision establishes package boundaries and records planned behavior.

## Package map

| Project | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Pure encounter decisions |
| [core/runtime](core/runtime/README.md) | Encounter supervision and effect dispatch |
| [core/store](core/store/README.md) | Clinical persistence and audit |
| [core/devices](core/devices/README.md) | Device capabilities and acquisition |
| [core/rtc](core/rtc/README.md) | Session signaling and transport |
| [core/media](core/media/README.md) | Signal profiles and recording |
| [core/interop](core/interop/README.md) | Healthcare record exchange |
| [core/web](core/web/README.md) | Shared clinician and patient interface |
| [apps/exam](apps/exam/README.md) | Connected remote examination |
| [apps/steth](apps/steth/README.md) | Remote digital stethoscope |

## Encounter flow

The product selects a workflow and signal profile. The runtime passes commands to the pure domain, then persists its decisions and effect intents. Device and transport adapters report outcomes back as new inputs. An accepted observation and its export intent share a transaction. Recordings live in encrypted object storage, with provenance and integrity references in the clinical record.

## Delivery sequence

1. Specify encounter commands, events, capability descriptors and signal profiles. Agree on replay, consent revocation and acquisition identity before implementing adapters.
2. Connect a simulated device and a one-to-one call to the remote exam workflow. Exercise disconnect, restart and export retry before integrating hardware.
3. Add stethoscope acquisition with separate preview and lossless paths. Validate recorded signals against the selected hardware and intended use.
4. Extend validated profiles to additional sensors and add multi-party transport as product needs emerge.

## Workspace commands

Use Elixir 1.18 or later in the 1.x series. Run from the repository root.

```sh
mix deps.get
mix setup
mix test
mix quality
mix weld.verify
```

Blitz installs child dependencies with `mix setup`, fans out ExUnit with `mix test`, and runs strict Credo and Dialyzer with `mix quality`. Weld verifies an internal monolith rooted in both applications, including the selected projects’ baseline suites and the projected suite. Each child also supports ordinary Mix commands in its own directory. Test directories currently contain only ExUnit startup.
