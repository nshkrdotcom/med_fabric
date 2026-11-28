<p align="center"><img src="assets/store.svg" width="200" alt="Clinical persistence and audit" /></p>

# Private native Store

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric"><img src="https://img.shields.io/badge/GitHub-med_fabric-345366" alt="GitHub repository" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/core/store/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_store` 0.2.0 is a private component composed into public `mf_exam` 0.3.0.
Every reusable operation receives an explicit database or transaction. Store
owns SQL; hosts supply authority/evidence inputs and use the public operations.
There is no reusable global pool selection.

## Schema and deployment

`Postgres.start_link/1` starts the caller-configured connection. Call
`Postgres.migrate(db, deployment_uuid)` explicitly. The one installed
`priv/sql/001_schema_v2.sql` baseline runs transactionally under an advisory lock
only in an empty schema. A current schema must have the exact revision,
migration checksum, schema fingerprint and immutable deployment UUID. An older,
partial, extra-table or changed schema is rejected; there is no migration chain
or legacy artifact reader.

The host independently holds the actual filesystem root lock and matches root
and database deployment identity. Use a dedicated service filesystem and one
capture service. Preserve the database, immutable objects/journals/indexes,
manifest files, producer ACK/spool state and external attempt inventory together.

## Ownership

| Module | Durable facts |
| --- | --- |
| `Encounters` | Membership, browser sessions, closure and optional export configuration |
| `DeviceSessions` | Device enrollment, authentication and clinician grants |
| `AcquisitionSessions` | Common source authority, reservations, attempts, scoped effects, frozen facts and manifest staging/promotion |
| `MeasurementEvents` | Exact canonical event identity/fingerprint and collection inventory |
| `DeviceCommands` | Bounded command grants, exact outcomes and settlement |
| `Records` | Manual evidence, review request replay, native observations and atomic intent creation |
| `Deliveries` | Mapping pins, claims/attempts, dispatch, confirmation, conflict, unresolved and remediation |
| `Recovery` | Checksum-bound authoritative restore inventory and fail-closed reconciliation |

## Transactions and external effects

The host takes its stream effect gate before entering Store's acquisition scope.
A failed SQL transaction cannot erase already synced journal bytes; unknown
outcomes require real writer retirement and storage recovery. Only committed
native observations can produce delivery intents. Acceptance has no mapping or
destination dependency.

Evidence and decision foreign keys include encounter and exact digest identity.
Manual evidence is exclusive with acquisition/manifest evidence. Immutable rows
and repeat/request identity prevent altered replay, cross-encounter evidence or
duplicate child decisions. Closure blocks new mutation while an authorized exact
committed request can return its original outcome.

Delivery state preserves pinned resource/destination/external identity and
attempt history. It distinguishes safe repetition from safe confirmation and
rejects stale result downgrade. A remote timeout or matching remote observation
is insufficient to erase a possible outstanding unsafe sender. Recovering a
backup requires accounting for post-backup native and remote effects, including
facts missing from restored rows; Boolean operator assertions alone cannot
establish that proof.

## Verification

Run unit tests and `mix test integration` against a disposable dedicated real
PostgreSQL database, then strict Credo, Dialyzer and ExDoc. Exercise actual backend
termination, concurrent closure/review, immutable constraints, delayed dispatch,
post-cutpoint restore gaps and two independent database contexts. The separate
`examples/clinical_core` host also uses real FHIR and never imports Exam. Do not
point destructive fixture setup at a retained deployment.

**License:** [MIT](LICENSE).
