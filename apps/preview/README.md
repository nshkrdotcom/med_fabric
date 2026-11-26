<p align="center">
  <img src="https://raw.githubusercontent.com/nshkrdotcom/med_fabric/main/apps/preview/assets/preview.svg" alt="Med Fabric Preview logo" width="200" />
</p>

<h1 align="center">Med Fabric Preview</h1>

<p align="center">
  <a href="https://github.com/nshkrdotcom/med_fabric/tree/main/apps/preview"><img src="https://img.shields.io/badge/GitHub-mf__preview-345366" alt="GitHub source" /></a>
  <a href="https://github.com/nshkrdotcom/med_fabric/blob/main/apps/preview/LICENSE"><img src="https://img.shields.io/badge/license-MIT-458f8b" alt="MIT license" /></a>
</p>

`mf_preview` is the optional isolated live-monitoring service in
[Med Fabric](https://github.com/nshkrdotcom/med_fabric). It runs in a separate
BEAM process with [`med_ex`](https://hex.pm/packages/med_ex),
[`med_ex_opus`](https://hex.pm/packages/med_ex_opus), and
[`med_ex_rtc`](https://hex.pm/packages/med_ex_rtc) so native Opus encoding and
WebRTC peer failures can never corrupt or interrupt authoritative clinical
capture in `mf_exam`.

## Installation

Add `mf_preview` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mf_preview, "~> 0.2.1"}
  ]
end
```

Requires Elixir `~> 1.20` (OTP 29), MedEx `~> 0.3.1`, and the Opus and RTC
providers at `~> 0.2.1`. Opus builds its pinned `libopus` source with a C11
compiler, GNU `make`, `tar`, `sh`, and `curl` or `MED_EX_OPUS_TARBALL`; it does
not require system `libopus` headers or ship precompiled encoders. RTC also
requires its native dependencies' build tools, including `pkg-config` and
OpenSSL development headers. Native qualification has been on Ubuntu Linux
`x86_64`; other platforms require separate qualification.

## How It Works

- **Loopback feed (`POST /feed`):** Authenticated with a dedicated bearer
  credential (`MF_PREVIEW_CREDENTIAL_FILE`) and `x-acquisition` header. Accepts
  valid 48 kHz mono PCM16LE (`MedEx.Wire.FrameV1`, stream 3, 960 samples /
  1,920 bytes) and stores only the latest frame per acquisition in ETS.
- **Signed viewer signaling (`POST /offer`, `/status`, `/close`):** Validates
  HMAC-SHA256 viewer tokens minted by `mf_exam` with short expiration windows,
  applies the server's ICE/TURN transport policy, and manages one
  `MedFabric.Preview.Peer` per acquisition.
- **Bounded latency & clean teardown:** Drops frames older than 200 ms, keeps
  at most one Opus encoding operation in flight per peer, closes superseded
  peers, and terminates idle peers after 65 seconds.

## Configuration

For a source checkout or unpacked Preview package, set the listener port and
shared secret file before starting:

```bash
export MF_PREVIEW_PORT=4090
export MF_PREVIEW_CREDENTIAL_FILE=/etc/med_fabric/preview.secret
mix run --no-halt
```

When Preview is a Hex dependency of a host project, the host must provide its
own runtime configuration: Mix does not execute a dependency's
`config/runtime.exs`. See the [Getting Started guide](guides/getting_started.md)
for the host setup and file-based deployment. Use a private random credential;
an empty or whitespace-only credential is rejected at startup.

## Guides

- [Getting Started](https://mf-preview.hexdocs.pm/0.2.1/getting_started.html) — Environment variables,
  credentials, and Mix release startup.
- [Isolation Model](https://mf-preview.hexdocs.pm/0.2.1/isolation_model.html) — Process, credential, and
  failure isolation from `mf_exam`.

## License

Released under the [MIT License](https://github.com/nshkrdotcom/med_fabric/blob/main/apps/preview/LICENSE).
