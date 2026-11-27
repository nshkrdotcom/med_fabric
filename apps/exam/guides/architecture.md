# Exam architecture

The package is composed once by Weld from Exam plus private Domain, Store and
Interop. Handheld and Preview are direct Mix packages. Only base MedEx supplies
shared technical receipt, stream, cursor, limit and immutable storage semantics.

| Owner | Responsibilities |
| --- | --- |
| `MedFabric.Domain` | Pure native evidence validation, exact values and review plans |
| `MedFabric.Store` | Explicit `db`/`tx`, all SQL, revision-2 authority, immutable native facts, outbox attempts and restore accounting |
| `MedFabric.Interop` | Mapping after native commit, bounded HTTP and typed remote confirmation |
| `MedFabric.Exam` | Authentication, common acquisition effects, root ownership, manifest installation, UI and worker composition |
| `MedEx` | Canonical technical receipt/limits, one fenced writer and verified file evidence |
| `mf_preview` | Optional media process with its own concrete codec/RTC resources |

## Acquisition lifecycle

`MedFabric.Exam.Acquisition` is the pure host transition owner. Store persists the
source-principal model, authority/generation, attempt reservations, receipts and
frozen source facts. `AcquisitionIngress` runs explicit side effects through
MedEx. Device and browser sockets enforce their transport/authentication details
and use that shared protocol; neither implements a second recorder or technical
receipt progression policy.

The lock order is stream effect gate, then Store scope. A PostgreSQL rollback
does not undo journal bytes. After an unknown effect, retire the old writer,
prove actual worker/OS quiescence and recover storage before issuing new
ownership or promoting a manifest. A database reservation without actual storage
is not a predecessor. An old authenticated acknowledgment proves historical
coverage only while its exact local binding remains active.

## Evidence and decisions

`AcquisitionManifest` builds canonical bytes from verified terminal indexes and
frozen authoritative facts. Stage, immutable install and database promotion are
separate recovery-aware steps. `AcquisitionWorkflow` serves exact verified
segments with descriptor-derived headers; the immutable manifest digest binds
review ranges. The host never reads private journal formats to bypass SDK proof.

Domain produces native review plans without database or FHIR effects. Store
locks the encounter and exact evidence, checks content/actor/request identity,
then commits decision, observations and pending delivery intents together.
Manual evidence uses native foreign keys and source XOR constraints rather than
a fake acquisition. Closed encounters deny new decisions while preserving exact
authorized replay of already committed outcomes.

## Outbox and external effects

`DeliveryWorker` maps native observations outside the acceptance transaction.
Store pins destination, references, mapping version, canonical resource bytes,
fingerprint and the deployment-scoped external identifier before dispatch.
Claims and results are bound to an immutable attempt ID. Confirmation is
monotonic, and conflict/unresolved/blocked/retryable are distinct persistent
outcomes.

Safe repeat requires proven noncommit with no stale sender, or qualified atomic
conditional create covering every possible outstanding request. Safe confirmation
also requires exact remote identity/content and no outstanding unsafe duplicate
possibility. One matching remote record does not alone settle a delayed unsafe
sender. Recovery and remediation preserve all pins and external identifiers.

`AcquisitionRecovery` is the non-listening host entry point for a blocked restore.
It gathers actual root-bound SDK journal proofs and installed manifest bytes
under the same stream effect gates, detects unknown artifact directories and
passes the verified inventory to Store's exact catalog reconciliation. A coherent
older database alone cannot authorize writable continuation.

## Startup, restore and optional effects

The host is the sole capture service holding its service-owned filesystem root
and real OS lock. Startup validates installed SQL/assets, schema fingerprint,
deployment UUID, root epoch and recovery state before enabling the listener.
There is no simultaneous writable clone or multi-node failover. A restore must
account for later durable native/remote effects and reclaimed producer records;
missing authoritative accounting blocks the scope or entire deployment.

Preview feed and ECG publication follow authoritative commit. Their loss cannot
prevent raw acquisition. Preview has short-lived signed, actor/session/source-
bound authority and a deadline checked at actual RTC submission. Direct browser
talkback is independently renewed cooperative media and cannot promise forced
server termination of an established noncooperating peer-to-peer connection.

See the repository failure matrix and release guide for the concrete fault,
independent-host, detached-archive and native performance acceptance gates.
