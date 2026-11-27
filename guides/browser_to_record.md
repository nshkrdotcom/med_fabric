# Browser microphone to native review

An authenticated patient first creates a page-bound acquisition through
`POST /encounters/:encounter_id/acquisitions/browser` with a bounded page instance
and stable creation request ID. The server allocates authority identity. The page
then connects to the authenticated browser stream endpoint, supplies actual
source descriptor/provenance in revision-2 hello and receives generation/fence,
credit and verified starting receipt before sending MEX1 frames.

Exam owns the microphone/worklet assets. At most 30 frame buffers cover assembly,
transferred messages, retained pending and in-flight data; at most 15 source
record operations and 262144 encoded bytes may be outstanding. Credit is separate
from durability. Backpressure cannot pretend the microphone paused without loss.
Actual rate/resampling and timing uncertainty are recorded without calibration
claims. Exact BigInt counters use canonical decimal strings.

Stop production, account for actual partial tail, send the short final batch,
checkpoint and await durable coverage, then seal and finalize. No padding or
silent discard. Same-page exact replay is allowed only with retained continuity
and fresh authorized binding. Page death/reload preserves the verified prefix as
interrupted; a new page normally creates a new acquisition/epoch.

Clinicians review the common immutable manifest and verified bounded segment
route. WAV is a descriptor-derived playback projection. Gaps remain explicit.
Browser review does not fabricate a clinical metric from a technically sealed
waveform. Manual pulse entry and clinician acceptance use native evidence and the
same decision transaction. Optional monitoring and talkback do not record evidence.

Direct talkback requires both cooperating clients to maintain a nonce/call-bound
authority interval of at most 30 seconds from monotonic request start, renewed by
default at 10 seconds. Failed renewal, signaling loss, closure or expiry tears
down tracks/peer/audio/timers; resume cleans up before further setup. Server
signaling cannot impose a hard cutoff on suspended/noncooperating P2P peers.
