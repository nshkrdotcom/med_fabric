# Getting Started

`mf_exam` is the Phoenix + LiveView server that coordinates encounters, device
admission, lossless waveform capture, clinical review, and HL7 FHIR R4 export.

## Prerequisites

- Elixir `~> 1.20` and OTP 29
- PostgreSQL (dedicated database and local recording artifact volume)
- Optional HL7 FHIR R4 endpoint (such as HAPI FHIR) for outbox delivery
- Optional `mf_preview` sidecar for isolated live acoustic monitoring

## Configuration

Key runtime environment variables (`config/runtime.exs`):

- `MF_LAB=1` — Enables the lab examination supervision tree (PostgreSQL
  connection, schema migrations, PubSub, and capture supervisor).
- `DATABASE_URL` — PostgreSQL connection string for encounter, evidence,
  acceptance, and outbox persistence.
- `MF_DEVICE_TLS_PORT` / TLS cert & key — Configures the device WSS listener
  for `mf_handheld` clients.
- `MF_PREVIEW_URL` & `MF_PREVIEW_CREDENTIAL_FILE` — Optional loopback sidecar
  configuration for isolated live monitoring.

## Running as a Mix Release

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release
_build/prod/rel/mf_exam/bin/mf_exam start
```

On startup, `MedFabric.Store.Postgres` executes the SQL migrations in
`priv/sql/` in filename order under an advisory transaction lock.
