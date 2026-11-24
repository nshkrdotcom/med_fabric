# Handheld

An ordinary Elixir Mix application owns the synthetic RDP1 and PLXS peripherals, local clock, command journal, bounded disk spool and independent Gun WSS connections. The producer accepts only a server URL, source configuration, trusted CA, device credential and its own spool. Run on Linux with util-linux flock, a local filesystem supporting directory fsync and OTP TLS. The measurement guarantee begins after handheld journal sync. The source clock, calibration and UTC trust used here belong to synthetic fixtures.

The two-process setup, production TLS options, source selection and CLI flags are in the [handheld runbook](../../guides/handheld_demo.md).

To deploy the producer without a server source checkout, build a normal Mix release in apps/handheld with the desired MedEx source context. Copy the release to an ordinary Linux host of the same architecture/ABI and provide its own credential, CA, fixture settings and spool. For example, from the release directory:

```bash
bin/mf_handheld eval 'Application.ensure_all_started(:mf_handheld); MedExHandheld.CLI.main(["--config", "/etc/handheld/fixture.json", "--scenario", "paired_exam"])'
```

Build that release with `MIX_ENV=prod mix deps.get` followed by `MIX_ENV=prod mix release`. Source-context paths for production are distinct from dev and test.
