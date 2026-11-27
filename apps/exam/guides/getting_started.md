# Getting Started

Exam 0.3.0 uses control/schema revision 2 and base MedEx 0.4.0. Choose the
qualified Elixir `~> 1.20`/OTP toolchain, PostgreSQL and a local filesystem with
working exclusive OS locking and durable sync. Create a new dedicated database,
artifact directory and immutable deployment UUID. Preserve that UUID across
restores of the same deployment; independent deployments need different UUIDs.

## Installed configuration

The startup reader uses `/etc/med_fabric/exam.json` outside Mix tests. Credential
files contain one trimmed value. Protect configuration, credentials, device
keys and artifact files with the service account's permissions.

```json
{
  "deployment_uuid": "68b49709-9c74-4b6e-998a-428afdc898a5",
  "encounters_file": "/etc/med_fabric/encounters.json",
  "artifact_dir": "/var/lib/med_fabric/artifacts",
  "database_url_file": "/etc/med_fabric/credentials/database-url",
  "secret_key_base_file": "/etc/med_fabric/credentials/secret-key-base",
  "http_port": 4000
}
```

Generate your own UUID and secret values. Use absolute paths. An encounter file
is an array of explicit memberships, for example:

```json
[
  {
    "exam": "synthetic-exam",
    "patient_actor": "synthetic-patient",
    "clinician_actor": "synthetic-clinician",
    "patient_key": "replace-with-private-random-patient-key",
    "clinician_key": "replace-with-private-random-clinician-key"
  }
]
```

For independently configured export, encounter entries may also supply
`destination`, `patient_ref` and `encounter_ref`. A missing configuration does
not prevent a native review. Mark `conditional_create_qualified` true only with
actual destination qualification and a retained `qualification_ref`; merely
supporting a FHIR header is not proof of atomic safe repetition.

| Optional setting | Purpose |
| --- | --- |
| `public_origin`, `proxy_secret_file` | Public HTTPS behind the authenticated proxy |
| `device_tls_certfile`, `device_tls_keyfile`, `device_tls_port`, `device_bind_ip` | Dedicated authenticated device WSS listener |
| `preview_url`, `preview_credential_file` | Same-host isolated Preview feed and shared private signing credential, at least 32 bytes |
| `turn_urls`, `turn_secret_file`, `relay_only` | Direct browser talkback ICE configuration |

The ordinary HTTP listener binds loopback. The exact encounter URL includes
`/encounters/<id>`; `/` is not a landing route. Local keys establish a signed
session, after which requests use the current encounter membership, role and
session. The public proxy path also checks current identity; a retained cookie
alone cannot authorize a replaced actor.

For controlled local launchers, `MF_LAB=1` enables the same host tree with
`MF_DEPLOYMENT_UUID`, `MF_ENCOUNTERS_FILE`, `MF_ARTIFACT_DIR`, `DATABASE_URL` and
`MF_SECRET_KEY_BASE`. Device TLS and Preview have the corresponding `MF_DEVICE_*`
and `MF_PREVIEW_*` inputs shown in `config/runtime.exs`. The file configuration
is the complete installed configuration when present. Do not store secrets in
source control, command output or qualification reports.

## Local checkout

From the repository root:

```bash
./ops/dev.sh up
./ops/dev.sh exam
# Separate terminals, as needed:
./ops/dev.sh preview
./ops/dev.sh handheld
./ops/dev.sh url
```

These tools use disposable synthetic data. Read the emitted settings before
starting services. Dependency development selection uses only the root
`.mix_sources.json`; private Domain/Store/Interop paths remain fixed. See the
repository release guide for exact candidate locks and source lanes.

## Composed release

Only `mf_exam` is composed by Weld. Inspect the installed Weld tasks, build the
initial monolith, verify its inventory and prepare its exact archive before
constructing a release. For a prepared projection with generated runtime
sources, carry those sources into the standard release overlay:

```bash
export MIX_ENV=prod
mix deps.get
version=$(mix run --no-start -e 'IO.write(Mix.Project.config()[:version])')
overlay="rel/overlays/releases/$version"
mkdir -p "$overlay"
cp -R config/runtime_sources "$overlay/"
mix release
_build/prod/rel/mf_exam/bin/mf_exam start
```

The direct source app has a single runtime configuration file; build it from
`apps/exam` without copying a generated runtime-sources directory that does not
exist there. An embedding application's dependency runtime file is not loaded
automatically: the host must install and exercise the equivalent configuration.

Startup acquires the actual root lock, validates package-relative SQL and all
three browser assets, applies the single fresh SQL baseline transactionally,
checks its checksum/schema fingerprint and deployment identity, reconciles
settled acquisition state, then starts the listener. A locked, incompatible,
incomplete or restore-blocked deployment must remain unavailable. Never fix a
startup refusal by deleting evidence or silently resetting the database.

## Native verification

Run every source project through formatting, `compile --warnings-as-errors`,
unit tests, `credo --strict`, Dialyzer and `docs --warnings-as-errors`. Also run
`elixir config/runtime_test.exs`, the browser Node suite, the real database and
HAPI suites, `ops/verify_browser.sh` and the native acceptance driver. The release
guide describes detached package testing and the independent clinical-core
consumer. Source startup alone is not installed-resource qualification.
