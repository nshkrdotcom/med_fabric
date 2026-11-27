# Isolation model

## Authority and data

Run Preview as a separate BEAM process and service user with access only to its
installed release and private relay credential. Do not mount authoritative
spool/evidence roots or provide database credentials. It imports no Exam,
Domain or Store module. Exam relay work occurs after successful protected
acquisition operations and cannot block source/checkpoint/clinical acceptance.

The service accepts only derived mono 48 kHz s16le, 960-sample (20 ms) MEX1
monitor frames on numeric handle 3. It validates acquisition, source kind,
profile, generation, source epoch and descriptor against each authenticated
viewer's capability. Raw recording bytes are not changed by monitor gain.
Missing listeners cause frames to be discarded without creating a media store.

## Bounded resources

The default global cap is 32 peers and four peers per source. Pending creation
counts toward both caps. A single feed owner tracks reservations, monitors peer
processes and releases entries after crash or abandoned negotiation. Request
admission is atomic, with one in-flight operation per viewer and a global bound
of twice the peer cap. Calls have bounded deadlines and dead request owners are swept.
No request limit is inferred from process mailbox length.

Each authorized peer has one latest frame slot, at most one encode request,
one Opus Port owner and one RTC peer. Feed updates replace the latest slot and
use an atomic per-peer 100-request/second admission bound. The media timer checks
frames every 15 ms and drops data older than 200 ms. Repeated feed cannot create
an unbounded queue. An idle peer expires after 65 seconds even if viewer grants
continue to renew; the shorter authority deadline always takes precedence.

A peer is temporary. Invalid negotiation, expired authority, owner/encoder/RTC
failure, unknown send result, close, stale source reset or registry/feed loss
retires resources and clears its slot. It never adopts stale native completion
from an earlier encoder/peer. The concrete providers clean their native/RTC
resources when their explicit owner exits, including a hard peer kill.

## Time

The first successfully submitted source frame establishes media origin and
logical emitted sequence 0. The first media tick is 0. Elapsed source samples
convert exactly to 48 kHz ticks, so a dropped source interval advances time but
does not consume emitted packet sequence. Sequence increments only on known
successful RTC submission. RTC alone converts these logical counters modulo
2^16 and 2^32. Backward coordinates or new source generation require a fresh
peer and origins; no invented source continuity.

A viewer grant lasts at most 25 seconds from the latest successful Exam check,
with at most two seconds of verified relative clock error conservatively
subtracted. Its deadline is derived once on receipt. Fresh renewal requires a
later issue time and different nonce for exactly the same owner/source scope.
Status/feed/idle activity and replay of a token cannot extend the deadline.
Deadline checks occur again at the actual RTC submission boundary. A suspended
peer must close at its first runnable opportunity past expiry. Already emitted
or in-flight packets are outside the recall guarantee.

## Evidence required

Qualify a real PCM → pinned libopus → RTP → independent receiver path, sequence
and timestamp gaps, direct and relay-only TURN, malformed feed/capabilities,
concurrent sources, viewer churn, exhausted budgets, provider kill/stall,
expired/lost renewal, clock drift and suspended-peer recovery. Run the sidecar in
another OS process and kill it during both device and browser capture; verify
sealed raw bytes, manifest identity and review/segment playback remain exact.
Direct browser talkback has its own cooperating-client grant model and does
not use this service or record evidence.
