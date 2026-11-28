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

Exam and Preview default to Logger `:info`; the Exam test configuration retains
its warning threshold. Installed executable consumers must import the package
configuration or set the same defaults themselves. Phoenix filters credentials,
session/lease/creation tokens and clinical/media fields. Store does not install a
query logger callback. Host-owned primary filters redact messages and arbitrary
metadata from the database, HTTP and media dependency namespaces, retaining the
original severity, a fixed category and a safe originating MFA when available.
They also redact OTP crash reports identified with those dependencies or clinical
host/SDK processes; unrelated OTP reports and fixed host diagnostics remain
visible. Installation is idempotent across host restarts. The filters remain
installed for shutdown reporting for the lifetime of that VM.
Runtime configuration is evaluated before these filters exist; malformed Exam
configuration therefore raises fixed categories without echoing JSON fragments,
credential paths, encounter bodies or invalid URL values. Delayed OTP crash
reports retain their ownership classification through the standard own-process
and neighbour report fields even after the originating PID exits.

The pinned `ex_webrtc 0.18.0` source includes warning paths that inspect transport
exit reasons and RTCP packets; an info threshold alone therefore cannot implement
this policy. See its [PeerConnection source](https://hex.pm/packages/ex_webrtc/0.18.0/files/lib/ex_webrtc/peer_connection.ex)
and the documented [Logger primary filter API](https://hexdocs.pm/logger/Logger.html#module-filtering).
This is a bounded policy for known Logger/OTP paths, not a guarantee about arbitrary
third-party direct stdout/stderr writes or newly introduced namespaces. Run the
secret-sentinel startup, SQL-fault and native failed-negotiation regressions in
the actual source and installed executable hosts before qualification.

Expiry and delivery workers, plus the optional Preview gateway, are siblings in
a one-for-one background supervisor after Endpoint. A child fault leaves the
other workers and admitted capture intact. Repeated fatal failures can still
exhaust OTP restart intensity; predictable database/poll/item failures use fixed
diagnostics and a bounded next poll. A failed delivery item defers its due time by
five seconds without consuming an execution, changing its disposition or clearing
a lease. Core database/schema/root/recovery failures retain the outer rest-for-one
fence and restart dependent acquisition and Endpoint.

An expired exact claim with only an immutable `claim/admitted` record can settle
as `noncommitted/expired_before_send`; the token is fenced in the same transaction.
Any committed send marker stays `unknown/claim_expired`, since an already admitted
HTTP effect can arrive late. Earlier uncertain attempts still constrain retry and
confirmation. Missing, mismatched or terminal current-claim history returns
`invalid_claim_history`; the expired token remains unusable and no historical
repair is made. This is a release-blocking corruption condition requiring a
separately authorized reconciliation plan, not permission to backfill old data.

Effective UID checks read the effective field of Linux `/proc/self/status` or use
a bounded, trusted absolute POSIX `id -u` executable when procfs is unavailable.
Identity resolution uses no VM-global cache. Every existing ownership boundary
retains fresh path, UID, lock and retirement validation; root owners additionally
pin device/inode identity so same-UID directory replacement cannot inherit a
held lock. Handheld rechecks its owned root before spool operations. Root lock
and flock requirements, unsupported platforms, and the ext4 qualification target
remain explicit; this UID fallback alone does not make those facilities portable.
Measure commit/recovery and full clean-soak performance on the final closure;
these changes do not establish a performance improvement.

See the release guide for approval and preservation prerequisites. No automatic
evidence deletion or destructive downgrade is permitted.


## Watching a candidate soak

From the Fabric root, run `./ops/soak.sh`. At startup it prints one
`tail -F` command for candidate preparation, capture and verification. During
capture, `soak-samples.jsonl` records audio and ECG progress, lag, host pressure
and database activity every five seconds. Each mode writes its verdict and
sampled timing summaries to `native.json`. For the inputs, automatic lock
commit and release gate selection, see `guides/releasing_exam.md`.
