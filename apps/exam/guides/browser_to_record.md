# Browser microphone, native evidence and review

Browser microphone is the `browser_microphone` acquisition profile. An
authenticated patient creates a server-owned acquisition bound to the current
encounter, actor, session and page incarnation. A clinician can review evidence
but cannot use that role to impersonate the patient's producer.

## Source and transport

Exam owns `priv/static/acquisition.js` and `acquisition_worklet.js`. The worklet
converts the observed device rate to 48 kHz mono PCM16LE and emits canonical
MEX1 frames. Sequence/sample coordinates use `BigInt`; conversion through
JavaScript `Number` is not permitted for protocol counters. Source settings and
provenance remain explicit; resampling is not a calibration claim.

The producer has bounded transferable buffer ownership across the worklet and
main thread, a bounded WebSocket send budget and negotiated frame/byte credit.
Frames remain locally retained until an authenticated, identity-matching durable
receipt proves the exact covered prefix. An accepted receipt only describes
volatile writer progress. Repeated acknowledgments release no additional credit;
a replaced connection's reply releases none. JSON control messages use strict
bounded decoding, including duplicate-field rejection.

A short final worklet batch is sent, explicitly checkpointed and durably drained
before terminal completion. Queue overflow produces explicit loss information;
it cannot become invented silence. Same-page reconnect may replay only bytes
still retained by that producer. Page reload or browser process loss cannot
claim offline continuity: the old acquisition is reconciled to its actual
interrupted prefix and a new server-owned creation is required.

## Storage and playback

Browser and handheld waveforms share `AcquisitionIngress`, the fenced MedEx
StreamWriter, immutable segment objects, journal, verified stream indexes and
`AcquisitionManifest`. There is one waveform recorder and no separate continuous
WAV artifact. Finish freezes the source inventory, settles old effects, verifies
terminal indexes, stages canonical manifest bytes, installs the immutable file
and commits the matching digest.

The playback route is:

```
/encounters/:encounter_id/acquisitions/:id/segment/:stream/:first_sample/:sha
```

It requires current authenticated membership and the exact reviewed manifest
binding. The host checks the verified index, expected stream/descriptor/fence/
journal identity and exact segment bytes. A descriptor-derived WAV header wraps
that segment for a browser player. Gaps are displayed and excluded from requested
ranges; they are never filled with samples. There is no read path through a
retired recording layout or unverified direct filesystem path.

## Clinical decisions

A waveform decision records explicit stream/sample ranges. `complete` requires
no manifest defects. `partial` requires the exact defect acknowledgment and a
reason. Range validation checks actual segment coverage and configuration epochs.
Reject/repeat are native decisions and do not require a FHIR destination. A
waveform review is not a fabricated pulse observation.

Manual pulse is a separate immutable native evidence row with actor, unit,
effective time and recorded time. A clinician can accept that exact evidence;
its review, native observation and pending delivery intent commit together.
Canonical request identity makes an exact authorized replay return the original
outcome, even after encounter closure. Changed content under that request ID is
a conflict, and closure prevents new mutation.

## Independent direct talkback

Talkback uses its own call ID, browser session, peer role, nonce and renewal
budget. Offers/answers and renewals require live authority. Cooperating browser
clients stop and close tracks/peers when renewal fails, signaling disappears,
the encounter closes or authority expires. Poll-start monotonic time prevents a
delayed renewal response from extending the grant.

The server controls signaling and grants. It cannot forcibly terminate an
already established peer-to-peer media path in a noncooperating client. This
limit is separate from Preview's server-owned RTC submission deadline.

## Verification

Run `node --test apps/exam/test/browser_acquisition_test.mjs` at repository root
for the immutable shared receipt corpus, strict control parser, atomic buffer
release, counters, credit, resampling and tail cases. `ops/verify_browser.sh`
drives real `getUserMedia`/AudioWorklet, compares independently observed MEX1 PCM
with all verified stored segments, restarts the host, rechecks playback, reviews
native evidence and checks remote delivery. Required browser/service absence is
not a passing result.
