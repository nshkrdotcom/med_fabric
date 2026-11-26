# Med Fabric Failure Matrix

Each row maps a component failure to its expected behaviour and the test or
acceptance suite that exercises it.

| Component | Failure | Expected Behaviour | Proving Test / Suite |
| --- | --- | --- | --- |
| `mf_exam` + `MedEx.StreamWriter` | Writer stalls or crashes mid-encounter | Independent encounters remain durable; fenced batching preserves only committed durable prefixes; no volatile frames leak across handoff. | `apps/exam/integration/device_network_test.exs`, `ops/handheld_acceptance.exs` |
| `mf_exam` + `MedEx.StreamWriter` | Capture reaches storage capacity | Terminal capacity receipt is preserved durably for both frame and gap submissions; no silent data loss. | `apps/exam/integration/device_network_test.exs` |
| `mf_exam` + PostgreSQL | Interrupted manifest promotion | Staged facts are preserved; reverification recovers finalized evidence cleanly. | `apps/exam/test/` + `ops/qc_native.sh` |
| `mf_exam` + PostgreSQL | Database unavailable at commit | Clinical acceptance and FHIR outbox intent fail atomically; no partial acceptance without outbox record. | `core/store/test/` + `ops/qc_services.sh` |
| `mf_handheld` + TLS uplink | Network drop / TLS disconnect | Handheld continues collecting into bounded local spool (5-frame audio batches, O(k) ack reclamation) and replays on reconnect with explicit multi-sequence gap handling. | `ops/handheld_acceptance.exs`, `ops/handheld/oracle_test.exs` |
| `mf_handheld` | Crash during staged spool write | Leftover temp files are swept on startup; partial batch spool recovers cleanly. | `apps/handheld/test/` |
| `mf_preview` | Opus encoder timeout or OS-process crash | Preview peer retires cleanly; authoritative capture and WAV/stream recording continue uninterrupted. | `guides/preview_isolation.md`, `apps/preview/test/`, `ops/verify_browser.sh` |
| `mf_interop` + HAPI FHIR R4 | Lost HTTP response / timeout on Observation export | Conditional create (`If-None-Exist`) + strict typed read-back confirmation make clinician-triggered retries idempotent and reject conflicting clinical values. | `core/interop/test/`, `ops/lab_fhir.exs` |
| `mf_exam` | Nonzero source epoch / clock uncertainty | Supported nonzero source epochs are admitted; review displays exact rational clock-uncertainty bounds rather than asserting point equality. | `apps/exam/integration/device_network_test.exs` |
| `mf_exam` | Out-of-range or non-contiguous review decision | Occurrence-aware review rejects non-contiguous ranges and mismatched occurrences before committing clinical decisions. | `apps/exam/integration/device_network_test.exs` |
