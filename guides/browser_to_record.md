# Browser to record

Use Ubuntu 26.04 and activate the Erlang and Elixir pins in `.tool-versions`
with asdf or mise. Install the native build tools listed by `onboard.sh`,
including pkg-config and OpenSSL headers. Install or configure PostgreSQL 18 and
an R4 FHIR server. For the local HAPI path, set `JAVA_HOME` to the full pinned
Temurin JDK 21.0.9. Use Node 24.19.0 for the browser check.

## Verify the exam release

```bash
./onboard.sh --integration
bash ops/verify_browser.sh --release
```

The runner uses separate patient and clinician browser contexts. It exercises
a direct WebRTC conversation, captures live Chromium microphone samples through
the AudioWorklet, replaces the clinician preview peer mid-capture, and recovers
the WAV and a manually entered pulse rate after an exam restart. It delivers
each accepted item separately and reads it back from HAPI. When the runner owns
HAPI, it restarts HAPI before the final read-back. Chromium provides deterministic
test input. The separate listening exercise below uses a real microphone.

Set `DATABASE_URL` and `FHIR_BASE_URL` to use existing test services. Leave
them unset to start native services in the run directory. The runner prints
the directory containing the release, service and exam logs. Use dedicated
test services because verification inserts synthetic clinical records.

## Verify the SDK from the local workspace

Prepare the MedEx projection with `mix weld.project` in its source checkout.
Use the existing private medical workspace registry to run the same exam
verification with that projection selected:

```bash
mix_workspace_ops run --project med_fabric.mf_exam --mode local \
  --registry "$HOME/.config/mix_workspace_ops/medical/registry.json" \
  --checkout-root .. --timeout 12m -- \
  bash -c 'set -e; mix deps.get; exec bash ../../ops/verify_browser.sh --release'
```

## Run the listening check

1. Start native services with `ops/local_services.sh start` and export the
   connection URLs it prints. Set `MF_EXAM_ID`, `MF_REFS_FILE`, and generate
   the synthetic references with `cd apps/exam && mix run --no-start ../../ops/seed_exam.exs`
   before enabling `MF_LAB`.
2. Set `MF_LAB=1`, `MF_ARTIFACT_DIR`, `MF_SECRET_KEY_BASE`, distinct
   `MF_PATIENT_ACTOR` and `MF_CLINICIAN_ACTOR`, and corresponding
   `MF_PATIENT_ACCESS_KEY` and `MF_CLINICIAN_ACCESS_KEY` with at least 32 bytes each.
   Start the exam from `apps/exam` with `mix run --no-halt`.
3. Open `http://127.0.0.1:4000/encounters/<id>?key=<key>` in separate browser
   profiles for each role. Use headphones. Join the conversation from each
   profile and confirm audio can be heard in both directions.
4. Open the diagnostic preview as clinician. Start capture as patient. Listen,
   disconnect the preview, reconnect it, and listen again before the patient
   finishes the recording. Confirm preview loss leaves capture running.
5. Play the finalized recording. Enter a measured pulse rate, accept both
   items, and deliver each to the test FHIR service. Record the browser,
   microphone, observed audio quality, and any issues.

## Focused checks

- `mix test` from the root runs the ordinary child suites.
- `cd core/store && mix test integration` verifies rollback and competing
  acceptance on PostgreSQL. Set `DATABASE_URL`.
- `cd core/interop && mix test integration` verifies HAPI read-back and retry
  after a lost response. Set `FHIR_BASE_URL`.

See [Architecture and roadmap](architecture_and_roadmap.md) for ownership and the
planned capability families.
