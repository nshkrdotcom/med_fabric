<p align="center"><img src="assets/med_fabric.svg" width="200" alt="Med Fabric" /></p>

<h1 align="center">Med Fabric</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

Med Fabric is an Elixir medical-device reference application built on
[MedEx](https://github.com/nshkrdotcom/med_ex). It connects device acquisition
to encounter-scoped review, durable clinical acceptance, and HL7 FHIR R4
delivery. Exam is the Phoenix server. Handheld is a standalone Mix application
that simulates reference peripherals and can collect while the uplink is down.
Preview is an optional service that runs in a separate BEAM.

## Workflows

- **Paired acoustic and ECG examination.** Admit a device to an encounter and
  record two independent waveforms. The reviewer can play verified acoustic
  segments, inspect ECG ranges and explicit gaps, and see which recorded
  ranges may correspond given the source clocks' uncertainty.
- **Pulse-oximetry spot check.** Collect synthetic PLXS events into a durable
  handheld spool and replay them after reconnecting. A clinician can mark a
  collection unusable, request a repeat, or accept eligible pulse-rate and
  oxygen-saturation measurements. Each accepted metric has its own retryable
  FHIR delivery record.
- **Browser examination.** Run two-way WebRTC talkback alongside patient-side
  lossless WAV capture and clinician-entered pulse rate. See the browser
  guide for the optional legacy media build profile.

MedEx supplies capture and device contracts. Fabric owns patient and encounter
identity, device enrollment and authorization, durable evidence and review,
and the decision to export. PostgreSQL commits clinical acceptance and its
FHIR outbox entries atomically. Optional monitor failures can interrupt
listening while authoritative capture continues.

## Run a local demonstration

Start the local dev lab (isolated PostgreSQL, localhost TLS certs, and shared
Preview credential) and run Preview, Exam, and Handheld in three terminals:

```bash
./ops/dev.sh up                          # prepares _build/handheld-demo, starts Postgres, prints browser URL
./ops/dev.sh preview                     # Terminal 1: isolated mf_preview sidecar (127.0.0.1:4090)
./ops/dev.sh exam                        # Terminal 2: mf_exam Phoenix server + device TLS listener
./ops/dev.sh handheld                    # Terminal 3: TLS relay + mf_handheld (paired_exam)
./ops/dev.sh handheld plx_spot_check     # Terminal 3 (optional): pulse-oximetry spot check
```

Open the exact **HTTP** encounter URL printed by `./ops/dev.sh url`
(`http://localhost:<http_port>/encounters/<exam>?key=<clinician_key>`). Do not
open bare `/` (Exam only serves encounter routes) or the HTTPS device port
(which uses the private lab CA for `mf_handheld` TLS WebSockets).

Once open in the browser, follow **Handheld examinations and review** to:
- play back verified acoustic segments and inspect ECG ranges, explicit gaps,
  and clock-uncertainty bounds from `paired_exam`
- review, request repeat, or accept `plx_spot_check` SpO2 and pulse-rate
  measurements
- enter manual pulse-rate readings and verify atomic acceptance

Exam starts the lab with grants for both scenarios, valid for two hours.
If a grant has expired, open **Handheld examinations and review**, select
**reference-gateway** and the scenario's protocol, enter the recording site,
and click **Confirm readiness and authorize collection**.

When finished, stop Terminals 1 & 2 with `Ctrl-C`, then run:

```bash
./ops/dev.sh down                        # stops isolated PostgreSQL
./ops/dev.sh reset                       # optional: removes _build/handheld-demo
```

Use Elixir 1.20 with OTP 29 and ordinary Mix in the application directories.
The default SDK and provider dependencies resolve from Hex using the ranges in
`config/sources.exs`. The [handheld guide](guides/handheld_demo.md) covers
resolving the app locks, selecting local sources, starting a native PostgreSQL
demo, and running TLS replay and recovery checks.
The [browser guide](guides/browser_to_record.md) covers the browser workflow.
The [preview guide](guides/preview_isolation.md) covers the isolated monitor.

The simulated runs exercise real software boundaries, including TLS,
PostgreSQL, browser playback, and HAPI FHIR in the relevant suites. Physical
peripherals, calibrated signals, clinical use, and production deployment
require separate validation. See [architecture and qualification](guides/architecture_and_roadmap.md).

The root Mix project provides optional Blitz orchestration. Run
`mix deps.get`, `mix setup`, and `mix test` at the root for the standard
workspace checks. Default Exam and Handheld use the base SDK. Build Preview
in its own project when native monitoring is required, or explicitly enable
legacy media in Exam for the browser examination.

## Projects

| Path | Responsibility |
| --- | --- |
| [core/domain](core/domain/README.md) | Validate audio and vital evidence constructors in pure Elixir |
| [core/store](core/store/README.md) | Commit encounters, evidence, acceptance, and outbox intents atomically in PostgreSQL |
| [core/interop](core/interop/README.md) | Map reviewed evidence to HL7 FHIR R4 and confirm idempotent delivery |
| [apps/exam](apps/exam/README.md) | Admit devices, host acquisition and browser endpoints, and serve clinical review |
| [apps/handheld](apps/handheld/README.md) | Standalone synthetic peripheral client, TLS transport and durable spool |
| [apps/preview](apps/preview/README.md) | Optional isolated monitor encoding, RTC and signaling |

## License

Released under the MIT License.
