# Med Fabric Failure Matrix

Each row maps a component failure to its expected behaviour and the source
tests that cover it. This is a coverage map, not a record of a passing 0.3.0
qualification run. The release must run the named suites against the exact
candidate packages. A path-existence check cannot establish that a scenario
passed; gaps are called out explicitly.

| Component | Failure | Expected Behaviour | Coverage / Remaining Gap |
| --- | --- | --- | --- |
| `mf_exam` + `MedEx.StreamWriter` | Writer stalls or crashes mid-encounter | Independent encounters remain durable; fenced batching preserves only committed durable prefixes; no volatile frames leak across handoff. | `apps/exam/integration/device_network_test.exs`, `ops/handheld_acceptance.exs` |
| `mf_exam` + `MedEx.StreamWriter` | Capture reaches a configured capacity limit | Terminal capacity receipt is preserved durably for both frame and gap submissions. | `apps/exam/integration/device_review_test.exs`: “frame and gap capacity return the same verified terminal receipt on reopen” exercises a duration limit. Physical disk-full failure is not covered by this case. |
| `mf_exam` + PostgreSQL | Interrupted manifest promotion | Staged facts are preserved; reverification recovers finalized evidence cleanly. | `apps/exam/integration/device_review_test.exs` forces a promotion conflict and rejects corruption before retry; `ops/handheld_acceptance.exs` injects `manifest_install` and `db_completion` interruptions. |
| `mf_exam` + PostgreSQL | Database unavailable at commit | Clinical acceptance and FHIR outbox intent must fail atomically. | `core/store/integration/postgres_test.exs` proves explicit transaction rollback, and `apps/exam/integration/device_review_test.exs` proves rollback when a second metric fails. **Gap:** neither injects an actual PostgreSQL outage at commit. |
| `mf_handheld` + TLS uplink | Network drop / TLS disconnect | Handheld continues collecting into bounded local spool (5-frame audio batches, O(k) ack reclamation) and replays on reconnect with explicit multi-sequence gap handling. | `ops/handheld_acceptance.exs`, `ops/handheld/oracle_test.exs` |
| `mf_handheld` | Crash during staged spool write | Leftover temp files are swept on startup; partial batch spool recovers cleanly. | `apps/handheld/test/spool_receipt_test.exs`: staged-write, partial-batch, and restart recovery cases. |
| `mf_preview` | Encoder death, timeout, or sidecar OS-process crash | Preview peer retires; authoritative capture continues when the isolated sidecar fails. | `apps/preview/test/feed_test.exs` covers normal encoder death; `apps/exam/integration/preview_isolation_test.exs` covers relay restart; `ops/handheld_acceptance.exs` with `--preview isolated` kills the sidecar during capture. **Gap:** Fabric does not inject an Opus Port timeout; provider timeout coverage belongs to `med_ex_opus`. |
| `mf_interop` + HAPI FHIR R4 | Lost HTTP response after Observation export | Conditional create (`If-None-Exist`) + typed read-back make clinician-triggered retries idempotent. | `core/interop/integration/hapi_integration_test.exs` and `core/interop/integration/device_fhir_test.exs` drop a response after a real HAPI write. Unit mapping/confirmation cases live in `core/interop/test/`. |
| `mf_exam` | Nonzero source epoch / clock uncertainty | Supported nonzero source epochs are admitted; clock bounds retain uncertainty. | `apps/exam/integration/device_network_test.exs` exercises the network admission/holdout suite; `apps/exam/test/clock_observations_test.exs` checks bounded alignment after long peripheral uptime. Exact browser formatting is a separate UI gate. |
| `mf_exam` | Out-of-range or non-contiguous review decision | Occurrence-aware review rejects invalid ranges and mismatched occurrences before committing clinical decisions. | `apps/exam/integration/device_review_test.exs` exercises occurrence-specific segments and rejects invalid review ranges. |
