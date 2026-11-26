# Core API Boundary, Compatibility Matrix, and Qualification

## 1. Reusable Core Boundary (`core/domain`, `core/store`, `core/interop`)

Keeping `core/domain` (`mf_domain`), `core/store` (`mf_store`), and
`core/interop` (`mf_interop`) decoupled from `apps/exam` preserves the option to
publish a reusable library once a second application defines its public API:

- **`MedFabric.Domain` namespace (`:mf_domain`):** Pure encounter, profile, review-range, and clinical-decision
  rules. Zero I/O, zero Phoenix/Ecto dependencies.
- **`MedFabric.Store` namespace (`:mf_store`):** PostgreSQL persistence, atomic clinical acceptance + FHIR
  outbox commits, and migrations.
- **`MedFabric.Interop` namespace (`:mf_interop`):** HL7 FHIR R4 Observation mapping, conditional create, and
  strict typed read-back confirmation.
- **Rule:** `apps/exam` must consume MedEx and core modules through their public
  APIs. The internal preview-session implementation and the removed Membrane
  modules are outside that public API.

These are existing internal package boundaries, not a published second-host
API contract. A reviewed function-by-function reusable API remains future work.

## 2. Package Compatibility Matrix

| Med Fabric | `med_ex` | `med_ex_opus` | `med_ex_rtc` | Status |
| --- | --- | --- | --- | --- |
| `0.2.0` (apps `0.1.1`) | `~> 0.2.1` | `~> 0.1.0` (Membrane) | `~> 0.1.0` | Qualified & released |
| `0.3.0` (apps `0.2.0`) | `~> 0.3.0` | `~> 0.2.0` (libopus Port, no Membrane) | `~> 0.2.0` | Prepared for coordinated release train (Weld `0.19.0` → MedEx family → Med Fabric apps). |
| `0.3.1` (apps `0.2.1`) | `~> 0.3.1` | `~> 0.2.1` | `~> 0.2.1` | Candidate |

## 3. Unified Qualification Pipeline

1. **Sources & boundaries:** `elixir config/sources_test.exs`,
   `elixir config/runtime_test.exs`, `elixir ops/check_hardening_test.exs`,
   `elixir ops/check_hardening.exs` (checks the file/suite paths cited in
   `guides/failure_matrix.md`), and `./ops/qc_sources.sh` with an explicit
   `MED_EX_SOURCE` selection. Run `node --test ops/docs_hook_test.mjs` for the
   workspace ExDoc navigation/theme hook.
2. **Native services & acceptance:** `./ops/qc_services.sh`,
   `./ops/qc_native.sh`, and `ops/handheld_acceptance.exs` against native
   PostgreSQL and HAPI FHIR R4.
3. **Browser & media:** `./ops/verify_browser.sh` (Chromium).
4. **Detached release:** `./ops/qc_detached_release.sh` verifying no native
   media deps leak into `exam` or `handheld`.

The root Blitz `mix test`/`mix quality` workflows intentionally omit Preview.
Run Preview's tests, format, compile, Credo, Dialyzer, and docs in `apps/preview`
as a separate native-provider lane. The existing Preview and Handheld `quality`
aliases include only format and compile; they do not run Credo or Dialyzer.
Use the command arguments required by each native runner (including report
paths), verify candidate archives against the committed locks in the signed local registry,
and retain the resulting evidence. This list does not attest that the pending
0.3.1 candidate has passed those gates.
