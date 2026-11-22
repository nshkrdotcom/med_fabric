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

## Proposed composition with MedEx

MedEx and Med Fabric can ship independently while sharing individual OTP applications. The first consumer is the connected exam. It needs the same stream profiles, browser media hooks and WebRTC session implementation as PulseScope. This proposal assigns one maintainer and one implementation to each shared responsibility.

| Responsibility | Proposed home | Consumer contract |
| --- | --- | --- |
| Stream specification, topology and integrity state | MedEx `med_core` | Products declare required streams and subscribe to their status. |
| WebRTC session, Opus, peer recovery and media pipeline | MedEx `med_rtc` | Med Fabric's `mf_rtc` connects encounter permissions and effect IDs to this runtime. Keep the adapter only while it owns that translation. |
| Browser tracks, signaling hooks and connection indicators | MedEx `med_web` | `mf_web` supplies the encounter workflow, review views and clinical authorization. |
| Device acquisition, durable encounter history, accepted observations and export | Med Fabric `mf_devices`, `mf_domain`, `mf_runtime`, `mf_store`, `mf_interop` | Persist an accepted observation and its export intent together. Give FHIR delivery one implementation here. |
| Recorded signal review | Med Fabric `mf_media` | Associate acquired artifacts and gaps with clinical provenance. Consume integrity results from MedEx. |
| Inference and biosignal integrations | MedEx `med_adapters` | PulseScope selects adapters through its product profile. |
| End-user workflows | Med Fabric exam and MedEx PulseScope | Exercise auscultation inside the exam via a profile. Keep the current `apps/steth` skeleton as a composition example until a separate product workflow emerges. |

The clinical encounter ID spans acquisitions and reconnects. Med Fabric owns its lifecycle. MedEx owns a live session's participants, transport and signal state. Correlate session ID, acquisition ID and encounter ID explicitly. A peer reconnect can create a new session while acquisition continues on the device. A stream event may update the UI immediately. Accepting an observation requires a separate clinical decision.

### Mix dependency boundaries

Start with a single downward edge from `mf_rtc` to `med_core` to exercise a real stream profile, then add `med_rtc` for the first call. Add `med_web` at the UI boundary when the shared browser hook exists. The pure `mf_domain` continues to work independently. Keep the initial repository dependency direction from Med Fabric into MedEx. If PulseScope later needs durable observations, first evaluate composing it in a product host that consumes both libraries. A reverse dependency between core packages would complicate independent releases.

From `med_fabric/core/rtc/mix.exs`, the local development tuple for the first edge is:

```elixir
{:med_core, path: "../../../med_ex/core/med_core"}
```

Use the producing child's actual OTP app in each tuple. Both repository roots are tooling projects. The current MedEx Weld artifact bundles four child apps into one OTP app named `:med_ex`. Mixing that bundle and the individual children in one deployment would supply the same modules twice. For the proposed child-level composition, give each externally consumed child a standalone source with the same app identity in every mode. Prove the complete transitive dependency closure from a clean checkout. In particular, fetching `med_rtc` from a nested Git project must also resolve its sibling `med_core` to the same source used by its consumer. A dedicated projected child package or projection branch is an option if the source checkout layout cannot satisfy that contract.

### Mix Workspace Ops rollout

1. **Inventory both workspaces.** Add their verified Git identities, actual visibility, Blitz roots and child app/path pairs to the operator's v2 portfolio registry. Use project IDs such as `med_fabric.mf_rtc` and `med_ex.med_core`. Create a medical view selecting both repositories. Keep machine paths, credentials and source preferences in operator state. Check registry visibility before adding private repository metadata.
2. **Wire the first consumer.** Keep intra-repo path dependencies ordinary. In each child with a switchable cross-repo edge, require the bootstrap file supplied by `MIX_WORKSPACE_OPS_BOOTSTRAP` when set, and wrap the committed tuple with `workspace_dep/1`. Follow the `switchyard/apps/terminal_workbenchd` example. The helper calls `MixWorkspaceOpsBootstrap.dep(committed, __DIR__)` when available and returns the committed tuple otherwise. MWO runs as an operator escript.
3. **Provide two usable sources.** For local development select the verified sibling project. For standalone use, pin a reachable private Git ref and the provider child subdirectory or projection. Declare eligible sources on the consuming registry project. Add Hex eligibility when a matching package actually exists. Verify a clean consumer clone resolves without the sibling or bootstrap before adopting the pin.
4. **Verify source switching and impact.** Run registry validation and doctor against the medical view. Inspect `seam`, `sources` and `why` for the first consumer under local and pinned Git modes. Check actual resolved app, path or revision and transitive identity. Run `impact` on the provider under the test environment. Expect the RTC adapter and its product consumers in the affected set. Record probe coverage.
5. **Exercise one shared vertical slice.** Establish a WebRTC call in the exam, acquire a simulated signal, interrupt the peer connection and reconcile acquisition status on reconnect. Run transport tests once in MedEx and encounter acceptance tests in Med Fabric. Use Blitz for child checks, MWO for cross-repo affected checks and Weld to verify the two artifact boundaries independently. Repeat the consumer checks from a sibling checkout and a clean authenticated standalone checkout.

Sibling patterns reviewed for this plan include codex_sdk, agent_session_manager, antigravity_cli_sdk, cli_subprocess_core, execution_plane, amp_sdk, cursor_cli_sdk, claude_agent_sdk, jido_hive and switchyard. Switchyard is the closest consumer example because one child combines ordinary in-repo paths and switchable external dependencies.
