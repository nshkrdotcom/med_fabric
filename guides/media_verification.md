# Native media and browser verification

Run actual pinned libopus decode and cleanup from the exact direct Mix package,
independent RTC negotiation with externally encoded packets, direct/relay-only
TURN, and isolated Preview media. Verify sequence/timestamp wrap and gaps,
peer ownership, startup/encode/ICE deadlines, late completions and process cleanup.
Fixture-native protocol tests are useful but do not prove the real pinned codec.

Browser qualification uses real getUserMedia/AudioWorklet with deterministic lab
audio. Compare actual MEX1 payloads and sealed raw segment bytes, exact counters,
resampling/rate provenance, saturation/endianness, short final batch and explicit
tail. Suspend the main thread while worklet runs to prove the entire 30-buffer
budget, not just page queue length. Test same-page lost ACK and truthful reload
interruption. Capture/review/playback must work without optional providers.

Exercise direct talkback in two browsers: current actor/call/session grants,
nonce-bound renewal from request start, expiry/closure/signaling-loss teardown,
delayed reply and suspend/resume cleanup. Record last successful authorization
and actual peer/track/audio/timer retirement. A suspended/noncooperating direct
P2P peer is outside a hard server media-cutoff guarantee; no relay is added.

Run full clean 1740-second Preview-off and isolated-on ext4 soaks with unchanged
lag guardrails, exact raw source oracle and measured process/queue/reclaim limits.
Separate intentional-fault runs from clean baseline acceptance.
