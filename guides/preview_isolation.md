# Optional monitoring isolation

mf_preview 0.3.0 runs in a separate BEAM, using med_ex_opus/med_ex_rtc 0.3.0
concrete providers. Exam and Handheld never install native providers. Raw source
spool/StreamWriter persistence happens before a latest-only disposable offer;
viewer media cannot supply a receipt, clinical decision or source configuration.

Each authorized peer owns one encoder and opaque RTC handle. A finite feed slot
and peer/request budget prevent mailbox/backlog growth. PCM format is validated
against source descriptor, epoch and generation. Freshness is 200 ms and idle
expiry 65 s; neither renews authority. Preview computes logical emitted sequence
and elapsed 48 kHz ticks, including dropped intervals; RTC converts modulo wire
counters. Unknown send/encode retires the peer.

Capabilities bind purpose, acquisition, source kind/profile, generation/epoch,
descriptor, viewer/session, issued time, expiry and nonce. Default signed lifetime
is 25 s with a maximum verified clock uncertainty of 2 s; local monotonic expiry
is conservative and cannot exceed 30 s from the authorization check. Renewal
requires a fresh Exam check. Recheck before allocation/feed/encode/send and at
RTC submission. Expiry/replacement closes encoder, peer and slot; previously
emitted network packets cannot be recalled.

Qualify absent/invalid/stalled/killed sidecar, peer churn, encoder/RTC faults,
expired delayed capability, ETS loss, bounded resources and raw byte equality
using actual separate OS processes. Direct and relay-only media and full
monitor-active 1740-second ext4 soak are mandatory; combined package smoke alone
is not isolation proof.
