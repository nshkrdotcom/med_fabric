# Getting Started

`mf_preview` is an optional sidecar service that encodes live 48 kHz mono
PCM16LE monitor frames into Opus and delivers them to clinician browsers over
WebRTC.

## Prerequisites

- Elixir `~> 1.20` and OTP 29
- C compiler and native build tools for `med_ex_opus` (`libopus` headers if
  building from source; precompiled binaries are used on supported Linux and
  macOS targets)

## Configuration

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

Development:

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
