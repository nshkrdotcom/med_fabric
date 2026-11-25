# Isolation Model

`mf_preview` exists to keep native media encoding (`med_ex_opus`) and WebRTC
peer negotiation (`med_ex_rtc`) completely outside the `mf_exam` BEAM.

## Security & Fault Boundaries

- **No clinical state:** `mf_preview` has no database URL, no device enrollment
  keys, and no access to authoritative recording volumes.
- **Dedicated OS isolation:** Run `mf_preview` under its own OS user or mount
  namespace that can read only its release directory and
  `MF_PREVIEW_CREDENTIAL_FILE`.
- **Failure independence:** If `mf_preview` crashes or is killed mid-recording,
  live listening stops cleanly while `mf_exam` continues recording and sealing
  authoritative clinical waveforms without interruption.

## Frame & Peer Lifecycle

1. `mf_exam` forwards validated `MedEx.Wire.FrameV1` monitor frames (stream 3,
   48 kHz mono PCM16LE, 960 samples / 1,920 bytes) to `POST /feed` with bearer
   auth and `x-acquisition`.
2. `MedFabric.Preview.Endpoint` stores only the single latest frame per
   acquisition in `:mf_preview_feed` ETS and returns `{"credit": 1}`.
3. Clinician viewers negotiate via `POST /offer` using short-lived HMAC-SHA256
   tokens minted by `mf_exam`. A replacement viewer closes the previous peer.
4. `MedFabric.Preview.Peer` keeps at most one Opus encode in flight, drops
   frames older than 200 ms, and exits automatically when WebRTC closes/fails
   or after 65 seconds without status heartbeats.
