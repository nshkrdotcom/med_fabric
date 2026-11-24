# Synthetic handheld lab

Med Fabric records two independent reference-peripheral waveforms or a sparse PLXS collection. The workstation and the handheld communicate using authenticated WebSockets over TLS. The synthetic source clocks, units, fixed UTC test fixture and status observations describe the simulator. Physical and clinical qualification requires ADC and oscillator measurements, calibrated channels and units, hardware dropout and restart testing, BLE conformance, deployment security, and clinician human-factors evidence for the intended use.

## Choose application sources

The committed Mix locks select the verified MedEx Git revisions for the SDK base
and optional providers. The published MedEx 0.1.0 package supports the legacy
contract. The stream-v1 applications use the verified Git source at product
version 0.2.0. Use a local source selection below when developing the SDK.

For a local implementation checkout, write this data file in the **Fabric root**:

```json
{
  "med_ex": {"path":"../med_ex"},
  "med_ex_opus": {"path":"../med_ex/extensions/med_ex_opus"},
  "med_ex_rtc": {"path":"../med_ex/extensions/med_ex_rtc"}
}
```

Name it `.mix_sources.json`. The build helper applies only dependencies declared by the current project. A path may also point to an explicitly chosen live/full Weld projection. Git source selections accept one GitHub/Git origin and one ref/branch/tag; Hex selection requires a versioned dependency. Source choices isolate **lockfile, deps and build paths** by project, toolchain and Mix environment. Remove the file to return to committed defaults. A simultaneous MF_MED_EX_PATH and selector file is rejected. The legacy environment variable supports existing automation during migration. Weld and MWS are maintainer tools and are absent from application dependencies.

Install Elixir 1.20.x/OTP 29, Hex/Rebar and the dependencies for each actual context. Leave MIX_BUILD_PATH, MIX_BUILD_ROOT, MIX_DEPS_PATH and MIX_LOCKFILE unset. From the Fabric root:

```bash
for project in core/domain core/store core/interop apps/exam apps/handheld; do
  (cd "$project" && mix deps.get && mix compile && MIX_ENV=test mix deps.get && MIX_ENV=test mix compile)
done
# Optional isolated native provider and legacy-browser contexts
(cd apps/preview && mix deps.get && mix compile && MIX_ENV=test mix deps.get)
(cd apps/exam && MF_EXAM_LEGACY_MEDIA=1 mix deps.get && MF_EXAM_LEGACY_MEDIA=1 mix compile)
(cd apps/exam && MF_EXAM_LEGACY_MEDIA=1 MIX_ENV=test mix deps.get && MF_EXAM_LEGACY_MEDIA=1 MIX_ENV=test mix compile)
elixir config/sources_test.exs
MED_EX_SOURCE='{"med_ex":{"path":"/absolute/path/to/med_ex"}}' bash ops/qc_sources.sh
```

The independent consumer script expects paths resolvable from its temporary consumer. Use an **absolute** checkout path in MED_EX_SOURCE. Repeat with a real reachable Git SHA, local/full and archive-cloned projection and released legacy Hex using EXPECT_MED_EX_CONTRACT=legacy. Record actual SHA, lock digest, default-lock restoration and native package versions during runtime QC.

## Process acceptance

Put PostgreSQL server binaries on PATH. On Ubuntu with PostgreSQL 18, use
`export PATH="/usr/lib/postgresql/18/bin:$PATH"`. The runner needs Python 3.10+, OpenSSL, util-linux flock, native PostgreSQL tools (initdb, postgres, psql on PATH), and bubblewrap with working unprivileged user and PID/mount namespaces on Linux. Run as a regular user. Preview and real browser gates also need Chromium, Playwright for Node and the matching Opus/RTC build prerequisites. Install the shared pinned browser dependencies with `(cd ops && npm ci && npx playwright install chromium)`. A spot-check gate uses a dedicated local HTTP HAPI R4 instance at FHIR_BASE_URL or starts a Docker HAPI container. MF_HAPI_IMAGE can specify the operator's verified HAPI image digest. FHIR integration creates synthetic Patient, Encounter and Device resources and checks an intentionally dropped POST response before retry.

```bash
elixir ops/handheld_acceptance.exs --suite paired --preview off
elixir ops/handheld_acceptance.exs --suite paired --preview isolated
elixir ops/handheld_acceptance.exs --suite spot-check --fhir hapi
elixir ops/handheld_acceptance.exs --suite legacy-browser
elixir ops/handheld_acceptance.exs --suite all --preview isolated --fhir hapi --report /path/to/report.json
```

Acceptance creates and removes a system temporary directory by default. Use `--report /path/to/report.json` to retain only the report or `--run-dir /path/to/new-lab` to retain the full run for investigation. The runner starts its own password-protected PostgreSQL cluster, Exam BEAM, client BEAM and a transparent loopback TLS proxy. Private per-role mounts hide the run tree, server artifacts, credentials, oracle and database from the handheld/sidecar. A 60-second baseline compares independently computed raw source and monitor bytes, verifies clock holdouts, cuts the uplink for ten seconds and proves audio and control make progress during a five-second ECG stall. Additional runs cover CRC/native formats, explicit 100-sample gap, source reboot interruption, capacity, stale generation, cross-encounter admission, conflicting replay and kill/restart at named file/journal/manifest/database boundaries. The spot-check runner kills the client after durable local ingestion, submits the final inventory before replay, loses an event response, exercises unusable/repeat/usable review and checks the two remote observations. Test-only barrier files under the private run directory are disabled in ordinary production runtime configuration.

Review report.json together with logs, chunk/index/manifest files, source identity markers, per-stream receipts and the wall-clock/host-monotonic observation. Required skips, missing prerequisites, expired deadlines and wrong outcomes fail the gate. A failed run can contain secret-bearing server.json and credential files. Keep its directory private. The report is synthetic engineering evidence.

## Separate terminals or remote handheld

```bash
elixir ops/handheld_demo.exs prepare --run-dir _build/handheld-demo
```

Preparation creates fixture configuration and localhost TLS material. Start
a private PostgreSQL cluster in the prepared directory. Run as a regular
user with the PostgreSQL server binaries on PATH.

```bash
lab="$PWD/_build/handheld-demo"
pg_port=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["postgres_port"])' "$lab/server.json")

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
python3 - _build/handheld-demo/server.json <<'PYTHON'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
config = json.loads(config_path.read_text())
sys.argv = [
    "ops/handheld/proxy.py", str(config["proxy_port"]), str(config["tls_port"]),
    str(config_path.parent / "outage"),
]
import runpy
runpy.run_path(sys.argv[0], run_name="__main__")
PYTHON
```

```bash
cd apps/handheld
mix run -e 'MedExHandheld.CLI.main(System.argv())' -- \
  --config ../../_build/handheld-demo/handheld-a.json --scenario paired_exam
```

For review, open
`http://localhost:<http_port>/encounters/<exam>?key=<clinician_key>`
using the first encounter in `server.json`. After the demo, stop Exam and the
proxy with Ctrl-C and stop PostgreSQL with
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
