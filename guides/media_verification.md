# Browser media verification

The browser capture checkpoint sends a generated 997 Hz mono microphone signal through Chromium's capture device. The patient sends indexed PCM to the exam and the clinician receives decoded Opus over WebRTC. Use a fresh synthetic encounter for each capture run. The checkpoint creates one recording and one manual pulse.

## Local run

For the unpublished MedEx candidate, run the following command from the Fabric checkout. Select the matching MedEx sources before running the browser checkpoints. [Prerequisites and workspace setup](browser_to_record.md)

```sh
elixir ops/handheld_acceptance.exs --suite legacy-browser
```

The wrapper controls the local PostgreSQL, HAPI and exam processes across three checkpoints. It prints the capture measurements as JSON, restarts the exam, accepts and exports both records, then checks remote identities and the WAV after restart. Both role contexts in the local scenario share one Chromium process.

## Relay run with separate network endpoints

Provision a patient machine and a clinician machine on different networks. Both must trust the exam's HTTPS certificate and reach the configured TURN server and its UDP relay port range. The server-side preview peer also needs outbound connectivity to coturn. Synchronize coturn and exam server clocks for REST credential expiry.

Run real coturn with REST authentication (`use-auth-secret`, `static-auth-secret` and a configured realm), a listener and relay addresses reachable by all peers. When coturn is behind NAT, map the advertised external address and relay port range to the relay interface. On the exam host export `MF_RELAY_ONLY=1`, `MF_TURN_URLS=turn:turn.example.test:3478?transport=udp`, `MF_TURN_SECRET` matching coturn's REST secret, and `MF_PUBLIC_ORIGIN=https://exam.example.test`. Use a dedicated synthetic encounter in `MF_ENCOUNTERS_FILE`. Put the authenticating HTTPS proxy ahead of the loopback Phoenix endpoint, including its WebSocket upgrade routes. The proxy strips incoming identity headers and supplies the authenticated actor and `MF_PROXY_SECRET` to the exam.

On each browser machine, install the checkout's pinned Playwright and Chromium. Launch one loopback endpoint on each machine.

```sh
cd ops/browser
npm ci
npx playwright install --with-deps chromium
MF_BROWSER_PORT=9333 node endpoint.mjs
```

Each launcher prints a private WebSocket endpoint with an unguessable path. Keep its terminal open. Use two SSH forwards from the control machine and retain each endpoint's path.

```sh
ssh -NT -L 19333:127.0.0.1:9333 patient-browser
# In a second terminal.
ssh -NT -L 29333:127.0.0.1:9333 clinician-browser
```

On the control machine, install the same pinned Playwright version. Create two role-specific Playwright storage-state files using the deployment's identity provider. For a cookie-based browser login, run the commands below in separate fresh sessions, complete the login as the indicated actor and close the browser to save its state. Keep the state files and endpoint paths private. The proxy must recognize each role session when used from its browser machine. Use deployment-provisioned role states if the identity provider binds sessions to the originating device.

```sh
cd ops/browser
npm ci
npx playwright install chromium
umask 077
mkdir -p "$HOME/.local/state/med-fabric-qc"
export MF_EXAM_ID=relay-trial-1
export MF_PUBLIC_ORIGIN=https://exam.example.test
export MF_PATIENT_STORAGE_STATE="$HOME/.local/state/med-fabric-qc/patient.json"
export MF_CLINICIAN_STORAGE_STATE="$HOME/.local/state/med-fabric-qc/clinician.json"
npx playwright codegen --save-storage="$MF_PATIENT_STORAGE_STATE" "$MF_PUBLIC_ORIGIN/encounters/$MF_EXAM_ID"
npx playwright codegen --save-storage="$MF_CLINICIAN_STORAGE_STATE" "$MF_PUBLIC_ORIGIN/encounters/$MF_EXAM_ID"

export MF_PATIENT_BROWSER_WS='ws://127.0.0.1:19333/<patient-endpoint-path>'
export MF_CLINICIAN_BROWSER_WS='ws://127.0.0.1:29333/<clinician-endpoint-path>'
set -o pipefail
node check.mjs --capture --relay | tee "$HOME/.local/state/med-fabric-qc/relay.json"
```

For the export checkpoints, set `FHIR_BASE_URL` on the control machine to the synthetic HAPI endpoint used by this encounter. Restart the exam on its host between checkpoints. The control machine needs read access to that FHIR endpoint. Refresh the browser endpoint variables if the endpoint processes restart.

```sh
node check.mjs --relay
# Restart the exam and HAPI with their persisted volumes, then rerun the read-back.
node check.mjs --relay --after-restart
```

The Chromium processes run on the endpoint machines. SSH carries Playwright control traffic. ICE, RTP, PCM, and authenticated page traffic originate at the browsers. The API requests that inspect authorized HTTP byte ranges originate at the Playwright API context, which carries the role's session cookies. Record endpoint networks, coturn version, exam/SDK revisions, and deployment configuration alongside the JSON for each run. Keep credentials out of the report.

## Interpreting the measurements

- **ICE and RTP.** The harness reads the transport's selected candidate-pair ID and checks for a succeeded pair. Relay mode requires both selected candidates to be `relay` for patient and clinician talkback and for the clinician-to-server preview. It reports transport protocol, round-trip time when exposed, received/lost packet counts, jitter in seconds and decoded sample count. Measurements include replacement and rejoin.
- **Setup and interruption.** Connect-to-state and join-to-media times are measured from the controller. The observing clinician also samples inbound audio counters on its own monotonic clock about every 50 ms. The reported gap spans the last observed increase on the displaced peer and the first on the replacement. Preview replacement includes the period listening from a second clinician tab. Sampling cadence, stats publication and control round trips affect these intervals.
- **Signal.** Decoded preview must exceed RMS 0.01 on a normalized scale and have an FFT peak within 30 Hz of 997 Hz, both before and after replacement. The finalized WAV must contain a 100 ms window whose rising zero crossings and RMS agree with the microphone tone. This fixture exercises the browser path. Named physical inputs and calibration require separate device evidence.
- **Lossless recording.** The harness hashes outgoing browser WebSocket PCM in order, checks every starting index, observes finish, then requires an exact SHA-256 and sample count match for the WAV data. The independent file digest is checked against the ETag and exported FHIR value. The SDK's `peakBufferedBytes` and `maxAckDelayMs` describe the PCM connection, including preview encoder startup while recording. The capture workload must fit the 32,776-byte logical bound.
- **Authorized seeking.** Concurrent clinician requests check exact 206 bodies and Content-Range for bounded and suffix ranges. A past-end request must return 416 and the total size. A patient request for the same byte range must return 404.
