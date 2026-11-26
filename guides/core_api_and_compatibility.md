# Core API Boundary, Compatibility Matrix, and Qualification

## 1. Reusable Core Boundary (`core/domain`, `core/store`, `core/interop`)

Keeping `core/domain` (`mf_domain`), `core/store` (`mf_store`), and
`core/interop` (`mf_interop`) decoupled from `apps/exam` preserves the option to
publish a reusable library once a second application defines its public API:

- **`MfDomain`:** Pure encounter, profile, review-range, and clinical-decision
  rules. Zero I/O, zero Phoenix/Ecto dependencies.
- **`MfStore`:** PostgreSQL persistence, atomic clinical acceptance + FHIR
  outbox commits, and migrations.
- **`MfInterop`:** HL7 FHIR R4 Observation mapping, conditional create, and
  strict typed read-back confirmation.
- **Rule:** `apps/exam` must consume MedEx and core modules through their public
  APIs—no private reach-ins to `MedEx.PreviewSession` or removed `Membrane`
  modules.

## 2. Package Compatibility Matrix

| Med Fabric | `med_ex` | `med_ex_opus` | `med_ex_rtc` | Status |
| --- | --- | --- | --- | --- |
| `0.2.0` (apps `0.1.1`) | `~> 0.2.1` | `~> 0.1.0` (Membrane) | `~> 0.1.0` | Qualified & released |
| `0.3.0` (apps `0.2.0`) | `~> 0.3.0` | `~> 0.2.0` (libopus Port, no Membrane) | `~> 0.2.0` | Prepared for coordinated release train (Weld `0.19.0` → MedEx family → Med Fabric apps). |

## 3. Unified Qualification Pipeline

1. **Sources & boundaries:** `elixir config/sources_test.exs`,
   `elixir ops/check_hardening.exs` (also verifies every path cited in `guides/failure_matrix.md` exists), and `./ops/qc_sources.sh`.
2. **Native services & acceptance:** `./ops/qc_services.sh`,
   `./ops/qc_native.sh`, and `ops/handheld_acceptance.exs` against native
   PostgreSQL and HAPI FHIR R4.
3. **Browser & media:** `./ops/verify_browser.sh` (Chromium).
4. **Detached release:** `./ops/qc_detached_release.sh` verifying no native
   media deps leak into `exam` or `handheld`.
