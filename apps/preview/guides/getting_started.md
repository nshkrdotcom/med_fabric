# Getting Started

`mf_preview` is an optional sidecar service that encodes live 48 kHz mono
PCM16LE monitor frames into Opus and delivers them to clinician browsers over
WebRTC.

## Prerequisites

- Elixir `~> 1.20` and OTP 29
- C11 compiler, GNU `make`, `tar`, and `sh` for the pinned-source `libopus`
  Port encoder; `curl` or an offline archive selected by an absolute
  `MED_EX_OPUS_TARBALL` path
- RTC native build prerequisites, including `pkg-config` and OpenSSL
  development headers (`libssl-dev` on Ubuntu)

Opus does not require system `libopus` headers or use precompiled encoder
binaries. The native qualification scope is Ubuntu Linux `x86_64`.

## Installing Exam and Preview in one Mix project

The normal deployment runs Exam and Preview as separate OS releases so native
WebRTC NIFs (`ex_dtls` / `ex_libsrtp`) stay isolated from authoritative capture.
Because `med_ex_opus ~> 0.2.0` runs a standalone C11 `libopus` Port encoder
with no Membrane dependencies, a single Mix project that includes both `mf_exam`
and `mf_preview` resolves cleanly from Hex with no overrides (requires POSIX
`cc`, `make`, `tar`, `sh`, and `curl` or `MED_EX_OPUS_TARBALL`; natively
qualified on Ubuntu Linux `x86_64`).

Both applications start in the host's BEAM when included as ordinary runtime
dependencies. A combined dependency graph does not provide process isolation;
deploy Preview in a separate host/release for the isolation guarantees below.

## Using Preview as a Hex dependency

Mix loads runtime configuration from the top-level host project. It does not
automatically load `deps/mf_preview/config/runtime.exs`. After adding
`{:mf_preview, "~> 0.2.0"}` and fetching dependencies, copy the supplied runtime
configuration into a new dedicated Preview host:

```bash
mix deps.get
mkdir -p config
cp -n deps/mf_preview/config/runtime.exs config/runtime.exs
```

If the host already has `config/runtime.exs`, merge the Preview configuration
from the packaged file into it. Keep the file contents in the host, so Mix can
copy its runtime configuration into a release without relying on a checkout
path. This configures both `:mf_preview, :listen` and
`:med_ex, :rtc_provider`. An explicitly managed host can set those same
application settings itself.

## Configuration

For a file-based deployment, create `/etc/med_fabric/preview.json`:

```json
{
  "port": 4100,
  "credential_file": "/etc/med_fabric/credentials/preview"
}
```

Use the same credential file content for Exam's `preview_credential_file`.
Preview listens on loopback. The file takes precedence over the environment
settings below outside Mix tests. Restart Preview after updating it.
The port must be in `1..65535`. Use a private random credential; empty or
whitespace-only credential files are rejected in both configuration modes.

`mf_preview` reads two environment variables at startup (`config/runtime.exs`):

- `MF_PREVIEW_PORT` — Loopback TCP port (`127.0.0.1`) for the HTTP endpoint.
- `MF_PREVIEW_CREDENTIAL_FILE` — Path to a private file containing the shared
  bearer secret used by `mf_exam` to authenticate `/feed` requests and sign
  viewer tokens.

Configure `mf_exam` with matching `MF_PREVIEW_URL` (for example,
`http://127.0.0.1:4090`) and `MF_PREVIEW_CREDENTIAL_FILE`.

## Quick Local Dev (Monorepo Checkout)

From the `med_fabric` repository root, `./ops/dev.sh` creates the shared
`preview.credential` file, wires it into `mf_exam`, and starts `mf_preview`:

```bash
./ops/dev.sh up       # creates preview.credential and prepares the dev lab
./ops/dev.sh preview  # starts mf_preview on 127.0.0.1:4090
```

## Running Locally or as a Release

From `apps/preview` in the source checkout, or an unpacked Preview package:

```bash
mix deps.get
MF_PREVIEW_PORT=4090 MF_PREVIEW_CREDENTIAL_FILE=/path/to/secret mix run --no-halt
```

Production release:

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix release
_build/prod/rel/mf_preview/bin/mf_preview start
```

A dedicated host project uses its own application/release name in the final
path and carries the runtime configuration described above.
