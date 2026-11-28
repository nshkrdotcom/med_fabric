<p align="center"><img src="assets/interop.svg" width="200" alt="Healthcare record exchange" /></p>

# Private healthcare interop

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/core/interop/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_interop` 0.2.0 is a private component composed into `mf_exam` 0.3.0. It maps
already committed native observations to FHIR R4, performs bounded HTTP and
returns typed remote outcomes. It neither accepts clinical evidence nor chooses
a reusable global database.

## Mapping after acceptance

`FhirClient.resource_checked/3` receives the native observation, the pinned
external identifier and explicit references. It returns a representation or an
explicit mapping error. Store acceptance does not call it. Missing references,
destination/configuration or unsupported representation leaves the valid native
decision intact and its delivery blocked for deliberate remediation.

Manual pulse and eligible PLX pulse/SpO₂ selections retain exact values, unit,
method, source event, measured/available time, device provenance and simulation
status. `MedFabric.Interop.JSON` preserves decimal JSON numbers without binary
floating-point rounding. `Observation.matches?/2` checks clinical content;
server IDs/version metadata and permitted enrichment are not substitutes for
exact identifier, quantity, reference, provenance and time comparison.

## Bounded delivery and confirmation

The host pins mapping version, canonical resource bytes, fingerprint, destination
and references in Store before dispatch. The external namespace derives from
the immutable deployment UUID and is retained across restore. Delivery results
remain tied to the exact Store attempt claim.

`deliver/2` performs conditional creation under the existing identifier and
returns matched, proven noncommit/permanent, conflict or unknown outcomes.
`reconcile/2` queries that same identifier and verifies remote identity/content.
Store alone decides whether an attempt result permits confirmed, retryable,
blocked, conflict or unresolved state. A matching record is insufficient if an
unsafe stale request could still create another resource. Conditional-create
safety requires retained qualification for the destination and every possibly
outstanding request, not an optimistic flag.

HTTP has bounded request/response/time limits. Automatic transport retries must
not turn unknown submission into duplicate clinical writes. Diagnostics omit
credentials, patient data, raw evidence and response payloads.

## Verification

Run unit tests for exact decimal serialization and typed content comparison.
Run `mix test integration` against actual disposable HAPI with unique synthetic
Patient/Encounter/Device references. Cover lost response, remote conflict,
multiple matches, database failure after remote success, delayed stale sender,
permanent proven noncommit and no-blind-retry behavior. Required services missing
from that selected lane are failures, not passing skips. The independent private
clinical-core host must prove native acceptance without export configuration and
later exact confirmed delivery with real services.

Run strict Credo, Dialyzer and ExDoc before composition. This private source
component is not separately published.

**License:** [MIT](LICENSE).
