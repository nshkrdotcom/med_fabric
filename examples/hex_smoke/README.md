# Med Fabric Hex smoke test

Run all six published packages in one Mix project using synthetic inputs.
You can copy this directory out of the Fabric checkout and run it on its own.

## Quick start on Ubuntu Linux

Install Elixir 1.20 with a compatible Erlang/OTP installation. Install Hex
and Rebar with `mix local.hex --force` and `mix local.rebar --force` if
they are missing. Install the native build tools:

```sh
sudo apt-get install build-essential pkg-config libssl-dev curl ca-certificates
```

From this directory, in a checkout path without whitespace:

```sh
mix deps.get --check-locked
mix test
```

The first build fetches Hex dependencies, builds the WebRTC native
dependencies, and compiles the Opus encoder. Subsequent runs reuse the
build. The test starts a loopback Preview listener on an ephemeral port
and uses local UDP for WebRTC. It needs no browser, PostgreSQL, or TURN server.

## What runs

- Exam serves its packaged JavaScript and the MedEx PCM worklet.
- Handheld runs a simulated pulse-oximeter report and validates the event
  through MedEx's measurement contract.
- Preview handles an authenticated offer and a synthetic MedEx PCM feed.
  Its C encoder produces Opus, and the MedEx RTC provider sends the packet
  to a local receive-only WebRTC peer. The test requires an RTP payload.

The tests call the local HTTP plugs directly. For the full device upload
and database-backed clinician workflow, see the
[Fabric local demonstration](../../README.md#run-a-local-demonstration).

## Native build notes

`med_ex_opus` downloads the pinned Opus 1.5.2 source archive, checks its
SHA-256, and links it statically into the encoder executable. It uses the
system C compiler and Make. You do not need a system Opus development package.
The default archive cache is `$HOME/.cache/med_ex_opus` or
`$XDG_CACHE_HOME/med_ex_opus` when set. To supply the archive yourself,
set `MED_EX_OPUS_TARBALL` to its absolute path before running `mix test`.
It must match the checksum in the package's `c_src/vendor/SHA256SUMS`.
That override supplies only Opus. Other native dependencies may still
need network access on a clean build.

See [LICENSE](LICENSE) for the example's license.
