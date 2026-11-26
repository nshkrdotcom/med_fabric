# Getting Started

`mf_exam` is the Phoenix + LiveView server that coordinates encounters, device
admission, lossless waveform capture, clinical review, and HL7 FHIR R4 export.

## Prerequisites

- Elixir `~> 1.20` and OTP 29
- PostgreSQL (dedicated database and local recording artifact volume)
- Optional HL7 FHIR R4 endpoint (such as HAPI FHIR) for outbox delivery
- Optional `mf_preview` sidecar for isolated live acoustic monitoring

## Installing Exam and Preview in one Mix project

The normal deployment runs Exam and Preview as separate OS releases so native
WebRTC NIFs (`ex_dtls` / `ex_libsrtp`) stay isolated from authoritative capture.
Because `med_ex_opus ~> 0.2.0` runs a standalone C11 `libopus` Port encoder
with no Membrane dependencies, a single Mix project that includes both `mf_exam`
and `mf_preview` resolves cleanly from Hex with no overrides (requires POSIX
`cc`, `make`, `tar`, `sh`, and `curl` or `MED_EX_OPUS_TARBALL`; natively
qualified on Ubuntu Linux `x86_64`).

Ordinary runtime dependencies start in the same BEAM. For fault isolation,
build and run Preview as a separate host/release. A Preview dependency also
needs the host-owned runtime configuration described in its Getting Started
guide; a dependency's `config/runtime.exs` is not loaded automatically by Mix.

## Configuration

### File-based deployment (current source)

Create `/etc/med_fabric/exam.json` on the deployment host before starting Exam.
The file is read at startup outside Mix tests. When present, it supplies the
entire Exam deployment configuration. Protect the files containing credentials
and encounter access keys so only the service account can read them.

```json
{
  "encounters_file": "/etc/med_fabric/encounters.json",
  "artifact_dir": "/var/lib/med_fabric/artifacts",
  "database_url_file": "/etc/med_fabric/credentials/database-url",
  "secret_key_base_file": "/etc/med_fabric/credentials/secret-key-base",
  "http_port": 4000
}
```

Use absolute paths. Credential files contain one value each. The encounter
file uses the existing encounter JSON format. Optional settings are
`public_origin` with `proxy_secret_file` for public HTTPS,
`device_tls_certfile` and `device_tls_keyfile` together for device TLS
(with optional `device_tls_port` and `device_bind_ip`),
`preview_url` with `preview_credential_file` for loopback Preview,
and comma-separated `turn_urls` with `turn_secret_file` and optional
boolean `relay_only`. Restart Exam after updating these files.
The Preview credential must contain a nonempty value after trimming
whitespace; use the same private random credential for both services.

### Environment-based launchers

Key runtime environment variables (`config/runtime.exs`):

- `MF_LAB=1` — Enables the lab examination supervision tree (PostgreSQL
  connection, schema migrations, PubSub, and capture supervisor).
- `DATABASE_URL` — PostgreSQL connection string for encounter, evidence,
  acceptance, and outbox persistence.
- `MF_DEVICE_TLS_PORT` / TLS cert & key — Configures the device WSS listener
  for `mf_handheld` clients.
- `MF_PREVIEW_URL` & `MF_PREVIEW_CREDENTIAL_FILE` — Optional loopback sidecar
  configuration for isolated live monitoring.

## Quick Local Dev (Monorepo Checkout)

From the `med_fabric` repository root, `./ops/dev.sh` bootstraps an isolated
PostgreSQL instance, TLS certificates, and Preview credentials automatically:

```bash
./ops/dev.sh up        # starts PostgreSQL and prints the clinician review URL
./ops/dev.sh preview   # Terminal 1 (optional isolated monitor)
./ops/dev.sh exam      # Terminal 2: starts mf_exam
./ops/dev.sh handheld  # Terminal 3: uploads a synthetic paired_exam
```

Open the exact HTTP encounter URL printed by `./ops/dev.sh url`
(`http://localhost:<http_port>/encounters/<exam>?key=<clinician_key>`). Bare
`/` is intentionally unrouted, and the HTTPS port is reserved for device TLS
WebSockets.

## Running as a Mix Release

From an unpacked Hex package or Weld projection, carry its generated runtime
sources into the release using Mix's standard overlay. Set deployment
environment variables before starting the resulting release.

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

The source checkout's Exam app has a single runtime configuration file. From
`apps/exam`, run the same build and start commands without the overlay steps.

On startup, `MedFabric.Store.Postgres` executes the SQL migrations in
`priv/sql/` in filename order under an advisory transaction lock.
