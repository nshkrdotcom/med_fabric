# Synthetic handheld lab

Med Fabric records two independent reference-peripheral waveforms or a sparse PLXS collection. The workstation and the handheld communicate using authenticated WebSockets over TLS. The synthetic source clocks, units, fixed UTC test fixture and status observations describe the simulator. Physical and clinical qualification requires ADC and oscillator measurements, calibrated channels and units, hardware dropout and restart testing, BLE conformance, deployment security, and clinician human-factors evidence for the intended use.

## Choose application sources

The default dependencies use MedEx `~> 0.2.0` and its optional providers
`~> 0.1.0` from Hex. Resolve the default app locks in Exam, Handheld, and
Preview with `mix deps.get`. Check the legacy media
profile in its own context. Stream-v1 applications require the revision-1
contract. A legacy SDK package with only browser capture cannot satisfy it.

For local MedEx development, create `.mix_sources.json` in the **Fabric root**:

```json
{
  "med_ex": {"path": "../med_ex"},
  "med_ex_opus": {"path": "../med_ex/extensions/med_ex_opus"},
  "med_ex_rtc": {"path": "../med_ex/extensions/med_ex_rtc"}
}
```

Paths resolve relative to this file. The build applies selections to declared
dependencies. Exam and Handheld use the base entry in their default profiles.
Preview and legacy Exam also use the two provider entries.
The selector accepts the MedEx family and Fabric's three internal library
names. Third-party dependencies continue to use their Mix declarations.

| Transport | Source entry example for `med_ex_opus` |
| --- | --- |
| Live projection | `{"path":"../med_ex/.weld/live/med_ex_opus"}` |
| Detached full projection | `{"path":"../med_ex/.weld/full/med_ex_opus/project"}` |
| Prepared project | `{"path":"../med_ex/.weld/releases/med_ex_opus/<identity>/project"}` |
| Pinned Git | `{"github":"nshkrdotcom/med_ex","ref":"<verified-full-sha>","subdir":"extensions/med_ex_opus"}` |
| Versioned Hex | `{"hex":"med_ex_opus","repo":"hexpm"}` |

Use the matching path or Git revision for each selected package. For the base
Git choice omit `subdir`. Git entries accept one `github` or `git` origin and
an exact 40-character commit in `ref`. A Hex choice uses the declaration's compatible
version requirement and needs a registry that actually serves the packages.
Installations from existing projections use ordinary Mix. Generate the views
in MedEx before choosing them in Fabric.

Selected sources and `MF_EXAM_LEGACY_MEDIA=1` get separate **lockfile,
dependency, and build paths**, keyed by project, active sources, toolchain,
Mix environment/target, native build flags, and profile. Dependency declarations,
locks, and composition inputs select a new resolution when the graph changes.
Ordinary editable library source uses Mix incremental compilation. Full and
prepared projects also fingerprint their actual compiler, asset, and verification
inputs, including regenerated candidates at the same path. Remove the source
file and clear the legacy profile to return to default paths. Leave
`MIX_BUILD_PATH`, `MIX_BUILD_ROOT`, `MIX_DEPS_PATH`, and `MIX_LOCKFILE` unset
when selecting either isolated context. `MF_MED_EX_PATH` is a deprecated
base-only translation for existing callers. Use it with no selector file.
An explicit Hex choice includes its Hex home, public repository URL/signing-key coordinates and mirror coordinates in
the build context, allowing a private registry rehearsal to use the same
repository name with separate state.

Install Elixir 1.20/OTP 29 and Hex/Rebar. From the Fabric root:

```bash
for project in core/domain core/store core/interop apps/exam apps/handheld; do
  (cd "$project" && mix deps.get && mix compile && MIX_ENV=test mix deps.get && MIX_ENV=test mix compile)
done
# Optional native monitoring and legacy browser profiles
(cd apps/preview && mix deps.get && mix compile && MIX_ENV=test mix deps.get)
(cd apps/exam && MF_EXAM_LEGACY_MEDIA=1 mix deps.get && MF_EXAM_LEGACY_MEDIA=1 mix compile)
(cd apps/exam && MF_EXAM_LEGACY_MEDIA=1 MIX_ENV=test mix deps.get && MF_EXAM_LEGACY_MEDIA=1 MIX_ENV=test mix compile)
elixir config/sources_test.exs
```

Check the family in fresh ordinary Mix consumers with `ops/qc_sources.sh`.
The smoke command's temporary consumers need absolute local paths:

```bash
MED_EX_PROFILE=all MED_EX_SOURCE='{
  "med_ex":{"path":"/absolute/path/to/med_ex"},
  "med_ex_opus":{"path":"/absolute/path/to/med_ex/extensions/med_ex_opus"},
  "med_ex_rtc":{"path":"/absolute/path/to/med_ex/extensions/med_ex_rtc"}
}' ./ops/qc_sources.sh
```

Select `base`, `opus`, `rtc`, or `both` to run one profile. Repeat with live,
full, prepared, verified Git, and genuine Hex sources as needed. The
historical standalone SDK check uses `MED_EX_PROFILE=base`,
`MED_EX_REQUIREMENT='== 0.1.0'`, and `EXPECT_MED_EX_CONTRACT=legacy` when
that package is available from the selected registry.

## Process acceptance

The Elixir acceptance runner starts the synthetic lab and its TLS relay.

```bash
elixir ops/handheld/oracle_test.exs
elixir ops/handheld/process_lab_test.exs
```

For alternate sources, use absolute paths or exact 40-hex Git commit IDs.
Run `MED_EX_SOURCE="$(cat .mix_sources.json)" ./ops/qc_fabric_sources.sh`
for actual Exam, Handheld, Preview and legacy Exam resolution and compilation,
including removal/restoration of the selector in a disposable copy.


### Inspect and reuse source qualification

From an application, inspect the source type and actual Mix state paths without fetching
dependencies.

```bash
(cd apps/exam && elixir ../../ops/source_context.exs)
(cd apps/exam && MF_EXAM_LEGACY_MEDIA=1 elixir ../../ops/source_context.exs)
```

Fabric reuses Hex's verified archives at download time. Each alternate profile keeps
its writable dependencies and BEAMs in its own context. Compiled dependencies may
embed absolute filenames and build inputs. The qualification cache reuses a verified
whole workspace at its original path, with an exclusive lock and content checks.
It accepts local paths, GitHub coordinates, and Hex selectors. Use `--no-cache`
for raw Git URLs.

```bash
export MF_SOURCE_QC_CACHE="$HOME/.cache/med-fabric-source-lanes"
MED_EX_SOURCE="$(cat .mix_sources.json)" ops/qc_fabric_sources.sh
MED_EX_SOURCE="$(cat .mix_sources.json)" ops/qc_fabric_sources.sh --no-cache
ops/qc_fabric_sources.sh --prune <printed-lane-digest>
```

The optional cache applies to the qualification command. Ordinary Mix development
keeps its existing private paths. Cache writes are scoped to owned entries and
the command removes temporary source selectors when it exits.

### Run native qualification with owned services

The following command creates an isolated PostgreSQL 18 database and digest-pinned
HAPI R4 container and reuses those processes across the native and browser checks
within the run. It also runs the detached three-release acquisition with a
separate database and role credentials.

```bash
ops/qc_native.sh --evidence /private/path/to/new-evidence
ops/qc_services.sh run -- bash -c 'cd core/interop && mix test integration'
```

Each invocation provisions fresh data and credentials. The wrapper verifies
loopback service readiness and cleans up its own PostgreSQL and container on
success, failure, or interruption. Add `--keep-failure` to retain private
diagnostic state. Use `ops/qc_services.sh status PRIVATE_SERVICE_DIR` to inspect
a retained run and `ops/qc_services.sh cleanup PRIVATE_SERVICE_DIR` to remove it
after the invocation exits. For the pinned source-built JDK route, use
`ops/local_services.sh start`, `status`, `env`, `restart-hapi`, and `stop`
with a dedicated `MF_SERVICE_STATE`.


Put PostgreSQL server binaries on PATH. On Ubuntu with PostgreSQL 18, use
`export PATH="/usr/lib/postgresql/18/bin:$PATH"`. The native Elixir process acceptance runner needs OpenSSL, util-linux setsid and flock, native PostgreSQL tools (initdb, postgres, psql on PATH), and bubblewrap with working unprivileged user and PID/mount namespaces on Linux. Run as a regular user. Preview and real browser gates also need Chromium, Playwright for Node and the matching Opus/RTC build prerequisites. Install the shared pinned browser dependencies with `(cd ops && npm ci && npx playwright install chromium)`. A spot-check gate uses a dedicated local HTTP HAPI R4 instance at FHIR_BASE_URL or starts a Docker HAPI container. MF_HAPI_IMAGE can specify the operator's verified HAPI image digest. FHIR integration creates synthetic Patient, Encounter and Device resources and checks an intentionally dropped POST response before retry.

```bash
elixir ops/handheld_acceptance.exs --suite paired --preview off
elixir ops/handheld_acceptance.exs --suite paired --preview isolated
elixir ops/handheld_acceptance.exs --suite spot-check --fhir hapi
elixir ops/handheld_acceptance.exs --suite legacy-browser
elixir ops/handheld_acceptance.exs --suite all --preview isolated --fhir hapi --report /path/to/report.json
```

Successful acceptance creates and removes a system temporary directory by default; failures retain private diagnostic logs. Use `--report /path/to/report.json` to retain only the report or `--run-dir /path/to/new-lab` to retain the full run for investigation. The runner starts its own password-protected PostgreSQL cluster, Exam BEAM, client BEAM and a transparent loopback TLS proxy. Private per-role mounts hide the run tree, server artifacts, credentials, oracle and database from the handheld/sidecar. A 60-second baseline compares independently computed raw source and monitor bytes, verifies clock holdouts, cuts the uplink for ten seconds and proves audio and control make progress during a five-second ECG stall. Additional runs cover CRC/native formats, explicit 100-sample gap, source reboot interruption, capacity, stale generation, cross-encounter admission, conflicting replay and kill/restart at named file/journal/manifest/database boundaries. The spot-check runner kills the client after durable local ingestion, submits the final inventory before replay, loses an event response, exercises unusable/repeat/usable review and checks the two remote observations. Test-only barrier files under the private run directory are disabled in ordinary production runtime configuration.

Review report.json together with logs, chunk/index/manifest files, source identity markers, per-stream receipts and the wall-clock/host-monotonic observation. Required skips, missing prerequisites, expired deadlines and wrong outcomes fail the gate. A failed run can contain secret-bearing server.json and credential files. Keep its directory private. The report is synthetic engineering evidence.

## Separate terminals or remote handheld

For local development from the repository root, `./ops/dev.sh` automates
PostgreSQL binary discovery, lab preparation, Preview secret wiring, and TLS
relay lifecycle:

```bash
./ops/dev.sh up                      # prepares _build/handheld-demo & starts Postgres
./ops/dev.sh preview                 # Terminal 1: mf_preview sidecar
./ops/dev.sh exam                    # Terminal 2: mf_exam server
./ops/dev.sh handheld                # Terminal 3: TLS relay + paired_exam
./ops/dev.sh handheld plx_spot_check # Terminal 3: PLXS spot check
./ops/dev.sh url                     # prints the HTTP clinician review URL
./ops/dev.sh down                    # stops Postgres (or ./ops/dev.sh reset)
```

Open the exact HTTP URL printed by `./ops/dev.sh url`
(`http://localhost:<http_port>/encounters/<exam>?key=<clinician_key>`), not
bare `/` or the HTTPS device port.

### Manual setup (custom or remote hosts)

```bash
elixir ops/handheld_demo.exs prepare --run-dir _build/handheld-demo
```

Preparation creates private synthetic fixture configuration and localhost TLS material.
Export a synthetic lab `FHIR_BASE_URL` before preparation if you will exercise delivery. Start
a private PostgreSQL cluster in the prepared directory. Run as a regular
user with the PostgreSQL server binaries on PATH.

```bash
lab="$PWD/_build/handheld-demo"
pg_port=$(jq -er .postgres_port "$lab/server.json")

initdb -D "$lab/pgdata" -U lab --auth-local=trust --auth-host=scram-sha-256 \
  --pwfile="$lab/postgres.credential" --no-locale
pg_ctl -D "$lab/pgdata" -l "$lab/logs/postgres.log" \
  -o "-k $lab/pghost -h 127.0.0.1 -p $pg_port" start
```

From the Fabric root, run each of these blocks in its own terminal.

```bash
cd apps/exam
mix run --no-start --no-halt ../../ops/run_exam.exs --config ../../_build/handheld-demo/server.json
```

```bash
elixir ops/handheld_demo.exs relay --run-dir _build/handheld-demo
```

The relay forwards encrypted TCP to the Exam TLS listener. Create the
`outage` file in the lab directory to close existing connections and reject
new ones, and remove it to allow reconnect. The demo uses Elixir, OpenSSL,
PostgreSQL tools, and `jq` for the commands above.

```bash
cd apps/handheld
mix run -e 'MedExHandheld.CLI.main(System.argv())' -- \
  --config ../../_build/handheld-demo/handheld-a.json --scenario paired_exam
```

For review, open
`http://localhost:<http_port>/encounters/<exam>?key=<clinician_key>`
using the first encounter in `server.json`. After the demo, stop Exam and the
relay with Ctrl-C and stop PostgreSQL with
`pg_ctl -D _build/handheld-demo/pgdata stop`.

For a remote handheld, set the server URL to a reachable DNS name and provision
a certificate valid for that name and trusted by the handheld. In ordinary
`MF_LAB` startup, `MF_DEVICE_TLS_CERTFILE` and `MF_DEVICE_TLS_KEYFILE` enable
device ingestion. `MF_DEVICE_BIND_IP` and `MF_DEVICE_TLS_PORT` select its listener.

The prepared harness config authorizes the synthetic encounter/site in advance. For manual readiness selection set authorize_scenarios to false. Enroll a device administratively with `DATABASE_URL=... mix run --no-start ../../ops/enroll_device.exs --device DEVICE --credential-file FILE` from apps/exam. Open the clinician URL for the encounter using its access key, follow **Handheld examinations and review**, select the enrolled device, profile and site and confirm readiness. The client then admits its descriptors and starts uploading. Review shows a verified per-segment audio player or ECG plot, explicit gaps, device/time qualifiers, upload state and the separate software-monitor command history. Select a verified source range and enter its stream:first:end for a paired review. The possible ECG correspondence uses both frozen timing bounds and lists only recorded ranges.

To run the PLXS fixture, copy the handheld configuration, set its `acquisition` field to a fresh ID, and pass `--scenario plx_spot_check` with that copy. The same ID/boot is used for resuming an interrupted internet link with its original spool; reusing an ID for a different descriptor or patient is refused. The fixture holds its original local measurement time and explicit synthetic UTC qualification across delayed upload. Only qualified eligible completed measurements can be exported. Accepting both metrics creates one immutable review and two independently retryable outbox rows in one transaction. Collection rows do not represent scalar observations.

Waveform spool defaults to 64 MiB and a single in-flight network frame per stream. Directory and file sync plus the Linux ownership lock are required. Use one authoritative Exam artifact root per configured database, one owner per device/acquisition spool and a service manager that observes actual process death before takeover. The protocol has no automatic network-filesystem or cross-host takeover. A reboot interrupts its source epoch; a new acquisition/boot can resume clinical collection after explicit reassignment. A committed receipt can confirm only a covered prefix on its bound stream/fence. Corruption, a missing acknowledged prefix or a timed-out disk operation blocks clean completion.

## Focused checks

```bash
(cd apps/handheld && mix test)
(cd core/domain && mix test)
(cd core/store && DATABASE_URL=... mix test integration/device_admission_test.exs)
(cd apps/exam && DATABASE_URL=... mix test integration/device_review_test.exs)
(cd core/interop && FHIR_BASE_URL=http://127.0.0.1:18080/fhir mix test integration)
(cd apps/exam && MF_NETWORK_SUITE=paired mix test integration/device_network_test.exs)
```

The process harness and TLS fault proxy exercise separate OS processes, real
sockets, forced outages and independent capture oracles. Treat a retained
lab as private because it contains generated certificates and credentials.
