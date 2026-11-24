# Preview isolation

The signed handheld sends software-monitor frames over a separate WSS connection. It sends a new frame only after credit, keeps one latest replacement and discards stale frames after 200 ms of local queue age. Positions and monitor configuration epochs travel in the binary header. The server enforces the raw audio binding, stream number 3 and native 48 kHz mono s16 shape. It forwards the MEX1 body and acquisition ID to a local sidecar on a separate scheduling path. Neither hop grants a durable receipt.

The sidecar validates a dedicated bearer credential and bounds each feed body. Its latest-only ETS table serves viewers with active peers. One native encoding operation is outstanding per peer. A replacement viewer closes the old peer. Peer PID events report connection status. The browser gathers ICE candidates, posts its offer using its existing clinician cookie and CSRF token, consumes the answer and polls status. The Exam server issues expiring viewer tokens and transfers its established TURN/relay policy. Each peer starts a new RTP sequence and sample clock. Network transit time remains unknown.

Set `MF_PREVIEW_URL` on Exam to a loopback HTTP listener, set
`MF_PREVIEW_CREDENTIAL_FILE` for both services, and set `MF_PREVIEW_PORT`
for Preview. In `apps/preview`, run `mix deps.get` and `mix run --no-halt`,
or build an ordinary release with `MIX_ENV=prod mix deps.get` followed by
`MIX_ENV=prod mix release`. Preview uses the base SDK and both native provider
packages. Choose matching sources as described in the
[handheld guide](handheld_demo.md).

Run Preview with access only to its own release and private credential.
Clinical artifacts, database credentials, and Exam's environment belong to
Exam. The isolated acceptance suite uses separate BEAM processes and
PID/mount namespaces, waits for browser audio, kills the preview process
group during recording, and compares authoritative source hashes afterward.

The in-VM legacy browser providers are a separate Exam build profile. Set
`MF_EXAM_LEGACY_MEDIA=1` for dependency resolution, compilation, tests, and
when starting the legacy Exam build or release. This profile uses separate
lock, dependency and build paths, even with the default Git sources. Default
Exam and Handheld use only `:med_ex`.
