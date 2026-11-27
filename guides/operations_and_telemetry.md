# Operations, restoration and telemetry

Use one authoritative Exam capture service per database/evidence namespace and
one exclusive trusted local root. Bind an immutable deployment UUID to both DB
identity and root marker. Root-lock loss stops writable service activity; restart
requires confirmed old-service/storage-worker/OS quiescence. No simultaneous
writable clones, shared-filesystem failover or automatic root reacquisition.

The schema bootstraps only empty or exactly current revision-2 state under an
advisory lock. Partial/unsupported schema refuses without reset. SQL and browser
assets resolve from the installed mf_exam application, not checkout paths.
Validate required production runtime settings, TLS/CA, pool bounds, secrets and
filesystem ownership before listener activation. Optional Preview may be absent;
an explicitly invalid configuration is an error, never insecure fallback.

Backup requires coordinated quiescence/inventory of DB cut point, deployment
UUID, journal/index/manifest hashes, device spool/ACK coverage and unresolved
pinned delivery attempts. An older internally consistent snapshot can omit later
irreversible actions. Use trusted later evidence/WAL/attempt records and remote
identity reconciliation to account for them. Never invent a missing decision or
new external ID. Quarantine affected scope and block writes/dispatch if accounting
is incomplete; block the entire namespace if scope cannot be bounded.

`MedFabric.Store.Recovery.block(db, cut_point)` explicitly blocks the namespace
using the retained PostgreSQL WAL LSN. Normal application startup refuses a
blocked deployment. Recovery runs through a separately constructed, non-listening
`MedFabric.Exam.Context` with the same explicit database, trusted artifact root,
exclusive root owner and writer registry. Establish actual service/storage and
delivery-sender quiescence first; a database flag is not proof of it.

`MedFabric.Exam.AcquisitionRecovery.inventory(context)` acquires the common
stream effect gates, checks every declared journal and installed manifest against
the blocked SQL catalog, and returns canonical inventory bytes, digest and cut
point. Preserve those exact bytes with the corresponding authoritative DB/WAL
and spool inventory. `AcquisitionRecovery.reconcile(context, bytes, digest)`
re-reads actual SDK recovery proofs under those gates and permits continuation
only when deployment identity, migration, cut point, native catalog, attempt
history, journals and manifests agree. Unknown artifact directories, missing
later facts or conflicting prefixes refuse recovery. The inventory is not an
operator assertion that no later effects exist, and this operation does not
invent absent decisions or reconstruct them from remote FHIR resources.

Record low-cardinality state codes, counts and latency/lag/drop/recovery metrics.
Keep logs private and bounded; no clinical payload, raw audio, SDP, token or
remote body. Observe pending frames/bytes, spool peak, mailbox/queue peaks,
checkpoint/ACK latency, recovery time, native process cleanup and actual reclaim
work. Keep source identity and exact archive checksums in qualification evidence.

See the release guide for approval and preservation prerequisites. No automatic
evidence deletion or destructive downgrade is permitted.
