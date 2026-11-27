# Reference Handheld laboratory

The paired profile produces distinct acoustic and ECG source streams; PLX produces
qualified measurement events without waveform placeholders. Run only against
disposable DB/evidence/spool namespaces with explicit enrolled credentials and
verified TLS. Reference/synthetic sources do not establish clinical readiness.

Use `ops/handheld_acceptance.exs` for paired, spot-check, browser-microphone and
fault cases, and `ops/qc_native.sh` for native orchestration. Full soak defaults to
1740 seconds; run `--suite soak --preview off` and separately
`--suite soak --preview isolated` on an actual ext4 volume. Short runs are
explicit diagnostics and cannot satisfy release soak. HAPI is required for
spot-check delivery proof.

Full native and 1740-second soak runs require `--artifacts` with all six exact
archive identities and the two prepared Weld identities, as described in the
[release guide](releasing_exam.md#exact-archive-inputs-for-native-gates). The
runner creates external Hex consumers and rechecks their installed bytes before
starting each role. The direct acceptance entry point receives those directories
through `--installed-consumers`; it cannot label source-only full or long soak
runs as release evidence.

Raw spool commit precedes optional monitor offer. Commands are derived monitor
controls with exact persisted boot/target/generation/fingerprint outcomes and
poll-start deadlines, not sensor calibration. Killing/stalling Monitor or Preview
must preserve raw source/journal/manifest equality and bounded upload/heartbeat.

Use source selectors for current checkout candidates, signed registry for exact
provisional archives, then final official detached installations after authorized
publication. Preserve sanitized evidence and all unresolved outcomes.

When the first durable waveform reply is lost, Handheld can recover without a
saved ACK. It verifies the authenticated predecessor handoff and all covered
local records before persisting the recovered ACK and reclaiming any bytes.
The gateway boot identifies the paired acquisition. Each peripheral retains its
own clock boot identity in the stream descriptor.

For PLX, Handheld declares the exact final event inventory before uploading
events. Exam keeps an incomplete inventory pending across restart. Handheld
replays retained events under a fresh authenticated binding and reclaims them
only after Exam confirms the exact sealed inventory.
