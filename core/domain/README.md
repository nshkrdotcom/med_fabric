<p align="center"><img src="assets/domain.svg" width="200" alt="Pure encounter decisions" /></p>

<h1 align="center">Pure encounter decisions</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_domain` is the pure functional clinical encounter domain of [Med Fabric](../../README.md). It has zero workspace or network dependencies: every encounter command and `:med_ex` producer fact transitions an immutable `%MedFabric.Domain.Encounter{}` struct deterministically.

---

## What This Owns (and Does Not Own)

**`mf_domain` owns:**
- `MedFabric.Domain.Encounter` (`new/1`, `close/1`, `request_acquisition/2`, `apply_fact/2`, `accept_acquisition/4`).
- Consumer acceptance invariants:
  1. Closed encounters reject new acquisitions (`{:error, :encounter_closed}`).
  2. Live preview disconnects (`:peer_connection_changed`, `{:preview_stream, _}`) stay strictly inside `transient_preview_state` and never taint or abort an acquisition.
  3. Redelivered `:capture_completed` facts with the same `(acquisition_id, artifact_sha256)` are idempotent (1 review candidate).
  4. Conflicting `artifact_sha256` for an existing `acquisition_id` marks the candidate `:conflict` and blocks acceptance (`{:error, :conflict_blocks_acceptance}`).
  5. Finalized captures are review candidates only; transitioning to an accepted observation + `:fhir_r4` export intent requires an explicit `accept_acquisition/4` call matching the exact digest.

**`mf_domain` does not own:**
- Live WebRTC sessions or audio capture (owned by `:med_ex`).
- Persistence transactions (`core/store`) or HTTP/FHIR transport (`core/interop`).

---

## Walkthrough

```elixir
{:ok, enc} = Encounter.new("enc_1") |> Encounter.request_acquisition("acq_1")
enc = Encounter.apply_fact(enc, {:capture_completed, %{acquisition_id: "acq_1", session_id: "s1", artifact_sha256: "sha1", interval_ms: {200, 1200}, continuity: :observed_continuous}})
{:ok, enc, %{observation: obs, export_intent: intent}} = Encounter.accept_acquisition(enc, "acq_1", "sha1", "clin_1")
```

See `test/mf_domain_test.exs` for all 3 executable tests.

---

## Commands & Verification

```bash
cd core/domain
mix test
mix credo --strict
mix dialyzer --force-check
```

## Related Packages

- [Med Fabric Workspace](../../README.md)
- [Runtime](../runtime/README.md)
- [Store](../store/README.md)
- [Interop](../interop/README.md)
- [Exam App](../../apps/exam/README.md)
