# Browser to record

This guide covers Ubuntu 26.04 prerequisites, running the automated release
verifier, building and running the compiled `mf_exam` Mix release directly, the
manual listening check, and optional local workspace SDK testing.

## Prerequisites (Ubuntu 26.04)

1. **System packages:**

   ```bash
   sudo apt-get install -y git curl tar build-essential pkg-config libssl-dev jq openssl
   ```

   *(Install `libopus-dev` as well if compiling `membrane_opus_plugin` from
   source instead of using precompiled binaries.)*

2. **Pinned runtimes (`.tool-versions` via `asdf` or `mise`):**
   - Erlang `29.1.2`
   - Elixir `1.20.5-otp-29`
   - Node.js `24.19.0` (required for `--integration` / Chromium verification)

3. **Native services (or external URLs):**
   - **PostgreSQL 18** server binaries (`initdb`, `pg_ctl`, `createdb`, `psql`),
     or an existing test database via `DATABASE_URL`.
   - **Temurin JDK `21.0.9+10`** (full JDK with `javac 21.0.9`) with `JAVA_HOME`
     set when using the built-in local HAPI FHIR 7.6.0 runner, or an existing R4
     FHIR server via `FHIR_BASE_URL`.

## Verify the source checkout

Select the matching MedEx source as documented in [the handheld runbook](handheld_demo.md). Run the retained browser gate against an isolated lab:

```bash
elixir ops/handheld_acceptance.exs --suite legacy-browser
```

## Operate the exam

From the Fabric root, create the dedicated volume, start the services and set the encounter identity in your shell:

```bash
umask 077
export MF_ENCOUNTERS_FILE="$PWD/_build/encounters.json"
export MF_ARTIFACT_DIR="$PWD/_build/capture-volume"
export MF_SECRET_KEY_BASE="$(openssl rand -hex 48)"
mkdir -p "$(dirname "$MF_ENCOUNTERS_FILE")" "$MF_ARTIFACT_DIR"
# Supply DATABASE_URL and FHIR_BASE_URL for your private test services.
export MF_EXAM_ID=exam-a MF_PATIENT_ACTOR=patient-a MF_CLINICIAN_ACTOR=clinician-a
export MF_PATIENT_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_CLINICIAN_ACCESS_KEY="$(openssl rand -hex 24)"
export MF_RELEASE_DIR="$PWD/_build/exam-release"
```

For a compiled release, set the legacy media source selection, then build the exam through its ordinary Mix project.

```bash
export MF_EXAM_LEGACY_MEDIA=1
(
  cd apps/exam
  mix deps.get
  env -u MF_LAB mix run --no-start ../../ops/seed_exam.exs
  env -u MF_LAB MIX_ENV=prod mix release --path "$MF_RELEASE_DIR" --overwrite
)
MF_LAB=1 "$MF_RELEASE_DIR/bin/mf_exam" start
```

Run the seed command sequentially for each synthetic encounter, changing the ID, actors and keys. It writes a private JSON array. Each entry carries its own patient/clinician actors, FHIR destination, Patient reference and Encounter reference. Boot binds those identifiers in PostgreSQL. Conflicting existing bindings fail startup. The lab seed marks its FHIR encounter in progress. To use existing resources, provision the file directly. Keep the file outside Git.

The local endpoint listens on `127.0.0.1` at `MF_HTTP_PORT` (default 4000). In separate browser profiles open the encounter with the relevant key, for example `http://localhost:4000/encounters/exam-a?key=YOUR_PATIENT_KEY`. The server exchanges it for a session and redirects. Select conversation microphones independently on each side. On the patient page select the diagnostic input, start capture, and finish. If the reply is lost, reload the same tab or select **Check recording outcome**. The clinician sees recording duration, source label and first-frame receipt time, can seek during playback and explicitly accept and deliver either evidence kind. Stop the release with Ctrl-C.

## HTTPS and relay

Keep the application bound to loopback behind an authenticating reverse proxy. Set `MF_PUBLIC_ORIGIN` to the external HTTPS origin and provision a random `MF_PROXY_SECRET` of at least 32 bytes in the proxy and exam. Authenticate every HTTP and WebSocket upgrade at the proxy. Strip any client-supplied `X-Exam-Actor` and `X-Exam-Proxy-Token` headers and inject the authenticated actor ID and secret. The actor must match a configured encounter participant. HTTPS mode uses the proxy identity in place of lab URL keys. Restrict backend and proxy secret access to the trusted host. Configure secure cookies and TLS at the public ingress.

Set `MF_TURN_URLS` to comma-separated TURN URIs and `MF_TURN_SECRET` to the shared coturn REST auth secret. The exam issues one-hour credentials when an authorized peer connects. Set `MF_RELAY_ONLY=1` for a forced-relay run. TURN transports the two WebRTC paths. The authoritative PCM stream uses a separate authenticated WebSocket. Use the remote media guide for two hosts, known-signal checks, connection and recovery times, and selected candidate-pair evidence. [Remote media verification](media_verification.md)

## Targeted checks

- `core/domain` runs pure evidence cases with `mix test`.
- `core/store` runs native transaction and encounter-isolation cases with `mix test integration` and `DATABASE_URL`.
- `core/interop` runs pure FHIR comparison cases with `mix test`. Run `mix test integration` with `FHIR_BASE_URL` for the native HAPI retry.
- `apps/exam` runs artifact, range and proxy cases with `mix test`, and the interrupted recording scenarios with `env -u MF_LAB mix test integration` and `DATABASE_URL`. Select the matching source in `.mix_sources.json`.
- The deployable exam currently pins the single dependency-constraint change from Ratio PR 131 at commit `05191db`. The lock resolves Numbers 5.2.5 and Decimal 3.2.0. Run `mix hex.audit` in the exam and review the pinned Git change separately. Remove the Git pin when a Hex Ratio release admits Decimal 3. MedEx itself continues to declare Hex dependencies. [Ratio PR 131](https://github.com/qqwy/elixir-rational/pull/131)

See [Architecture and roadmap](architecture_and_roadmap.md) for storage ownership and clinical invariants.
