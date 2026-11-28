<p align="center"><img src="assets/domain.svg" width="200" alt="Pure encounter decisions" /></p>

# Private clinical Domain

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/core/domain/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_domain` 0.2.0 is a private source component composed into public `mf_exam`
0.3.0. It is not a seventh package. Its pure functions own native clinical
eligibility and review plans, without PostgreSQL, Phoenix or HTTP effects.

- `Evidence` constructs and validates immutable manual pulse evidence with
  explicit actor, exact decimal value, unit, effective time and recorded time.
- `NativeValue` parses bounded canonical mantissa/exponent pairs with integer
  arithmetic. Negative pulse is ineligible; pulse above 100 is allowed. SpO₂
  requires the native inclusive 0–100 range, independently of FHIR mapping.
- `DeviceMeasurement` validates canonical SDK measurement events against their
  exact PLXS raw indication, status, times and measuring-device provenance.
- `Review.plan/6` accepts a verified immutable source, actor, request ID,
  decision content and explicit time. It returns stable native decision and
  observation identities, or a native validation error.

Waveform ranges must be covered by real segments within the appropriate
configuration epoch. Complete review requires no defects; partial review must
acknowledge the exact defects and include a reason. Native manual evidence and
measurement-event selections produce observations; waveform review, reject and
repeat do not create fake clinical measurements.

Domain never selects a destination or calls FHIR. Store atomically commits a
valid plan and any resulting delivery intents. If a multi-metric native choice
contains an invalid metric, the plan fails as a whole. A representational failure
later in Interop does not retroactively invalidate native acceptance.

Run `mix test`, `mix credo --strict`, Dialyzer and ExDoc in this component. The
private `examples/clinical_core` consumer exercises Domain/Store/Interop with two
explicit databases and real FHIR without importing Exam. See the repository
[clinical-core guide](https://github.com/nshkrdotcom/med_fabric/blob/mf_exam-v0.3.0/guides/clinical_core.md).

**License:** [MIT](LICENSE).
