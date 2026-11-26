# Operations, Startup Config, Bounds, and Telemetry

Statements below were checked against the source on 2026-11-26. Items marked
**Gap** are not implemented or not yet proven by a test.

## 1. Startup Config

- `apps/exam/config/runtime.exs` reads required settings with
  `System.fetch_env!/1` (or a packaged settings map via `Map.fetch!/2`), so a
  missing required value fails at boot with a clear `KeyError`/env error.
- `apps/preview/config/runtime.exs` requires `MF_PREVIEW_PORT` and reads the
  shared credential from `MF_PREVIEW_CREDENTIAL_FILE`.
- **Gap:** no single documented list of required settings and no test that boots
  each app with each required value removed.

## 2. Bounds and Backpressure

The following bounds are stated in the changelog and implemented in the named
areas; they have not been re-audited in this pass.

| Surface | Bound |
| --- | --- |
| Handheld audio spool | 5-frame (100 ms) batched commits; crash-leftover temp sweep |
| Exam waveform writer | Host-fenced 15-frame pipelined batching with `checkpoint_ms: :manual` |
| Preview encode | One in-flight encode per provider, 1 s deadline, provider retired on timeout |
| Review streaming | Range streaming with bounded memory |

**Gap:** no systematic mailbox/queue audit.

## 3. Migrations

SQL migrations ship in the Exam release. Native suites (`ops/qc_services.sh`,
`ops/qc_native.sh`) run them against PostgreSQL. **Gap:** no upgrade-from-0.2 or
rollback test.

## 4. Telemetry

Only two events exist today, both in `apps/exam/lib/mf_exam/device_ingress.ex`:

- `[:mf_exam, :device_ingress, :checkpoint]`
- `[:mf_exam, :device_ingress, :writer_checkpoint]`

Each carries `duration_us` and `%{stream, acquisition_id}`. **Gap:** no events
for admission, spool depth, replay, review decisions or FHIR outbox delivery, and
the soak runner measures lag itself rather than consuming telemetry.
