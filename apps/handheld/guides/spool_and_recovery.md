# Spool and recovery

## One durable local owner

Each acquisition uses one `MedFabric.Handheld.Spool` process and one real OS `flock`
child. Concurrent ownership is refused. A fresh spool has `namespace.json`
containing schema `mf_handheld.spool` and revision `2`. A nonempty directory
without that exact marker is incompatible and is preserved for operator review.
No startup routine converts or resets an old namespace.

The persisted source identity includes device, encounter, acquisition, profile,
boot and API revision. Each waveform directory stores its immutable descriptor.
Installed records use `<sequence>-<first_sample>.rec`, with a 32-byte SHA-256
followed by the exact MEX1 frame or gap payload. Including both coordinates lets
a sample-only gap and its following frame have distinct filenames. Source
progression and gap validity are planned through the SDK `StreamCursor`.
Gap payloads are canonical JSON with exactly `id`, `first`, `end`,
`first_sequence`, `next_sequence`, `irreversible` and `cause`; coordinates are
canonical decimal strings. There is no second gap file representation.

A source batch contains at most five records. Each record is staged, file
synced and exclusively linked. One directory sync covers all newly installed
records before the batch reply, including a partial prefix on refusal. Restart
syncs recovered record names before reuse. A crash can leave a prefix. Restart
reconstructs it from checksummed installed records, the saved source watermark
and the previous durable ACK. Missing or conflicting coverage is refusal,
never manufactured source samples. Known staging remnants are not committed
records. A caller timeout or effect exception requires recovery before reuse.

The default byte budget is 67,108,864; metadata is bounded to 100,000 retained
records. Capacity refusal retains required evidence. Physical ENOSPC can fail a
write, sync or terminal operation and is distinct from logical capacity.

## Connection and receipt validation

Each active waveform binding includes `acquisition`, `profile`, canonical
`generation`, unique `connection`, `stream`, `fence` and `journal_id`.
`accepted` is volatile. `durable` and `stream_finished` contain a separate strict
11-field SDK receipt. Activation parses the receipt before field access,
requires full durability, verifies descriptor/binding and progression, then
proves coverage before replacing valid local recovery state.

A fence change requires an authenticated host assertion describing the actual
previous receipt, successor receipt and imported prefix. Handheld compares any
newer previous receipt through `Receipt.observe`, verifies the handoff through
`Receipt.handoff`, and independently proves every newly covered local interval.
The device trusts the authenticated host storage assertion; it does not claim
to have independently read the server filesystem.

`ack.json` atomically contains the binding and canonical receipt. This file is
synced before record deletion. After restart one bounded sweep reclaims records
covered by an already persisted ACK. Subsequent ACKs visit only newly covered
records and expose `reclamation_visits` for the native complexity measurement.
Repeated ACKs do not release credit or delete a second time. Local invalidation
or connection replacement rejects late replies from the old incarnation.

## Credits, final drain and events

The SDK credit ledger tracks each distinct outstanding frame/gap by operation
identity, fingerprint, encoded bytes and planned ending sequence/sample. A gap
consumes one slot and its complete encoded control size. Exact outstanding
replay consumes no additional slot; conflicting replay is refused. A matching
known refusal releases its charge while retaining source bytes. Unknown effects
retire the connection and reconcile through a newly authorized binding.

Source stop freezes exact produced coordinates and flushes the final batch.
The uploader explicitly checkpoints pending records before waiting for their
ACK, then seals only after durable coverage. A lost terminal reply uses the same
open/reconcile path. A restarted source ends at the verified local tail with
`source_reset`; it does not regenerate missing physical time.

PLX `events/<sequence>.rec` retains the canonical SDK `MeasurementEvent` body,
including exact characteristic bytes, sparse metrics, source statuses and
explicitly qualified or unknown source time. `events/binding.json` retains the
last admitted connection metadata solely to reject generation rollback; it
does not grant new authority. Each durable event ACK
binds its event ID and canonical fingerprint to the active control connection.
The complete authenticated final inventory is persisted as `events/seal.json`
before event files are reclaimed. A crash during reclamation resumes against
that identical inventory; a waveform receipt never acknowledges an event.
An exact authenticated final inventory also reconciles an event whose individual
ACK was lost; each surviving local body is verified before its deletion.

## Optional derived monitoring

Raw spool success precedes `Monitor.offer/3`. The offer overwrites one ETS batch
and returns without a monitor call. A missing table, dead/suspended monitor or
trace failure does not change raw source evidence. The monitor is temporary and
has its own trace budget. One atomic control slot bounds commands under
suspension. The poll nonce, boot, generation and deadline are checked before
application, with deadlines anchored to poll start and current local authority.
An exact persisted result contains application time and first derived source
coordinate. Current gain alone never resolves a historical unknown outcome.
