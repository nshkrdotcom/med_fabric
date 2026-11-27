# Getting started

Install `{:mf_preview, "~> 0.3.0"}` into a separate release. Use the same pinned
six-package revision-2 release family as Exam and Handheld, with exact locks and
archive checksums recorded for qualification. Preview is built directly from
`apps/preview` using Mix and compiles the pinned native codec through its direct
provider dependency.

Create `/etc/med_fabric/preview.json` (or explicitly set `MF_PREVIEW_CONFIG`):

```json
{
  "port": 4200,
  "credential_file": "/etc/med_fabric/preview-token",
  "trusted_clock": true,
  "clock_error_ms": 2000,
  "max_peers": 32,
  "max_source_peers": 4,
  "ice_servers": [],
  "ice_transport_policy": "all"
}
```

The credential is a protected absolute file with a 32–4,096-byte secret, also
configured on Exam's private relay. `trusted_clock: true` is an operator
assertion backed by verified same-host time or an established bounded relative
clock error. Without it the service refuses to boot. `MF_PREVIEW_PORT` and
`MF_PREVIEW_CREDENTIAL_FILE` explicitly override the corresponding file values;
blank or malformed values fail. The listener is loopback only. A remote sidecar
requires an explicitly secured private transport deployment, not an open
listener configuration.

ICE servers/policy come from trusted service configuration and are validated by
the concrete RTC provider before allocation. An untrusted offer never supplies a
remote feed endpoint or ICE configuration. `relay` requires qualified TURN
configuration. Record platform, browser, TURN and pinned libopus identities in
native qualification evidence.

Exam uses the following bounded private HTTP API. Each request carries the
private bearer and `x-acquisition`:

| Path | Body/headers | Result |
|---|---|---|
| `POST /offer` | JSON `token`, `sdp` (SDP ≤32,768 bytes) | Answer SDP for the authorized viewer |
| `POST /status` | JSON `token` | Current disposable media state; no lease extension |
| `POST /renew` | JSON fresh `token` | Fresh monotonic authority deadline after a new Exam check |
| `POST /close` | JSON `token` | Close only the same authorized viewer/source/session |
| `POST /feed` | MEX1 monitor frame; `x-generation`, `x-source-epoch`, `x-descriptor-ref` | Disposable credit response; no evidence acknowledgment |

The signed canonical JSON claims are exactly: `purpose` (`monitor`),
`acquisition`, `source_kind` (`device` or `browser`), `profile` (`paired_exam` or
`browser_microphone`), canonical `generation` and `source_epoch`, descriptor
SHA-256, `viewer`, `viewer_session`, canonical `issued_at_ms` and
`expires_at_ms`, and unique `nonce`. The token is unpadded base64url payload plus
`.` plus an HMAC-SHA256 over the exact canonical bytes. Duplicate, extra,
noncanonical or mismatched fields are refused before peer creation.
