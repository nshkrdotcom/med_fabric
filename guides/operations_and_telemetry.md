# Operations, Startup Config, Bounds, and Telemetry

## 1. Startup Config and Secrets Contract

`mf_exam`, `mf_handheld`, and `mf_preview` validate required runtime
configuration at boot (database URL, endpoint secret key base, TLS listener
certificates/CA for device ingress, shared Preview credential, and FHIR base URL
when export is enabled). Packaged releases preserve complete endpoint
configuration in `config/runtime.exs`.

## 2. Bounded Queues, Spools, and Mailboxes

| Surface | Bound / Backpressure |
| --- | --- |
| Handheld audio spool | 5-frame (100 ms) batched commits, live spool watermarks, O(k) sequence-range ack reclamation, crash-leftover temp sweep |
| Exam waveform writer | Host-fenced 15-frame pipelined batching with explicit `checkpoint_ms: :manual` |
| Monitor / Preview commands | Bounded monitor command queue; at most one in-flight Opus encode per provider with 1 s deadline and retire-on-timeout |
| Review HTTP artifact streaming | Same-descriptor HTTP Range streaming with bounded memory |

## 3. Migrations (Upgrade and Rollback)

SQL migrations live in `core/store/priv/repo/migrations` and are packaged into
the standalone Exam release. Native qualification (`./ops/qc_native.sh` and
`./ops/qc_services.sh`) exercises migrations against native PostgreSQL.

## 4. Telemetry and Soak Lag Detection

Key operational signals emitted across capture, spooling, and review:

- **Admission & batching:** acquisition admission, host-fenced batch commit
  latency, and checkpoint receipts.
- **Spool & replay:** live spool depth/watermarks and ack reclamation progress.
- **Soak gate:** the native 29-minute ext4 soak runner measures sustained
  throughput and stops early on sustained lag.
- **Review & FHIR outbox:** clinical acceptance commits and retryable FHIR
  Observation delivery outcomes.
