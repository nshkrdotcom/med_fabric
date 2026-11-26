# Getting Started

`mf_handheld` runs as an independent Elixir application or Mix release that
connects to an `mf_exam` server over TLS WebSockets.

## Prerequisites

- Elixir `~> 1.20` and OTP 29
- Linux with `util-linux` `flock` and a local filesystem supporting directory
  `fsync`
- A running `mf_exam` endpoint with a trusted CA certificate and an enrolled
  device credential

## Quick Local Dev (Monorepo Checkout)

From the `med_fabric` repository root, run the full stack with `./ops/dev.sh`:

```bash
./ops/dev.sh up                      # prepares lab & starts PostgreSQL
./ops/dev.sh exam                    # Terminal 2: starts mf_exam
./ops/dev.sh handheld                # Terminal 3: TLS relay + paired_exam
./ops/dev.sh handheld plx_spot_check # Terminal 3: PLXS spot check
```

## Configuration

The CLI accepts a JSON fixture file (`--config`) describing the server URL,
trusted CA path, device credential, spool directory, and synthetic peripheral
parameters.

Run from a checkout:

```bash
mix deps.get
mix compile
mix run -e 'MedExHandheld.CLI.main(["--config", "/path/to/fixture.json", "--scenario", "paired_exam"])'
```

## Built-in Scenarios

- `paired_exam` — Runs synthetic acoustic (`RDP1`) and ECG streams concurrently
  against an admitted encounter, verifying paired capture and replay.
- `plx_spot_check` — Collects synthetic pulse-oximetry (`PLXS`) spot-check measurements
  into the durable spool and delivers them for clinician review.

All peripheral signals, clocks, and calibration data produced by `mf_handheld`
are synthetic reference fixtures intended for software verification rather than
clinical diagnosis.
