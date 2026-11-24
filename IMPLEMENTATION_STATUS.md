# Implementation status — November 24, 2026

The source develops two simulated clinical workflows: a paired acoustic/ECG examination and an offline/replayed PLXS pulse-oximeter spot check. The server owns enrollment, encounter authorization, stream generations, immutable manifests, clinical review, derived metrics and FHIR outbox delivery. `apps/handheld` is ordinary Elixir; `apps/preview` is an optional separate native-media BEAM. The current product version is preserved; no release is authorized.

The implementation includes verified WSS transport, device protocols and checksums, durable local spool, explicit gaps/reset/capacity outcomes, bounded clock intervals, persisted monitor-command outcomes, Linux file ownership locks, independent heartbeat liveness, PostgreSQL migrations and transactional acceptance, segment playback/inspection and clinical review controls. Exact finite decimals are retained through PostgreSQL JSONB and FHIR JSON. Simulation labels and source device/time remain distinct from gateway, receipt and review facts.

## Evidence boundary

No Elixir/OTP, PostgreSQL or container runtime was available during implementation. No server/handheld end-to-end, migration, ExUnit, native media, browser or HAPI workflow is claimed green. Python/shell/JavaScript syntax checks and Git whitespace checks passed for inspected helpers. A real loopback TCP test verified the fault proxy's exact 65,792-byte forwarding, active connection cutoff, outage rejection and reconnect; this is proxy-only evidence.

Independent review corrected FHIR instant comparison, remote ID and malformed Bundle handling, and strengthened permanent tests. The real HAPI lost-reply test forwards an actual write before discarding the upstream response. Database tests exercise competing admissions, stale leases, revocation, unknown commands, concurrent two-metric review and rollback of every derived/outbox effect when the second metric fails.

The device review also tightened receipt identity and local-prefix checks before spool retirement, prevented historical sample regeneration after a source restart, separated command admission from blocked stream locks, and preserved unanswered-command uncertainty at manifest finalization. Session resource ownership now covers initialization and interrupted connection attempts; focused cleanup regressions are included for runtime QC.

## Required closure

Restore the established root `VERSION` from the actual repository if it is missing; the supplied snapshot omitted that file. Resolve each selected source context separately for dev and test. Recompile Postgrex with the committed exact JSON codec. Pin new MedEx API consumers to a real verified reachable source SHA after SDK QC; old Hex remains an explicit legacy lane.

Run each headless project, source selection tests, database integration tests and the complete OS-process acceptance matrix. Qualify all crash barriers, independent sibling/heartbeat progress, strict current-fence spool retirement, frozen manifest recovery, native preview process death and real HAPI read-back. Use the updated guides and the separate QC handoff for exact prerequisites and commands.

Retain the simulator, provider application, fault scenarios, independent oracles, browser and database regressions. The Python process runner and transparent fault proxy are essential until replaced with equivalent passing integration coverage; deleting them while their Elixir entrypoints depend on them would remove a required gate. Scratch probes and generated lab data are disposable. Engineering evidence does not establish physical-device or clinical validity.
