# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-26

### Breaking changes

- Compose concrete Opus and RTC providers in a separate optional BEAM service.
  Remove base media facades, global selection and private handle matching.
- Bind viewers and feeds to source/generation/purpose with finite capacity and
  conservative monotonic authorization deadlines; retire stale resources.
- Compute emitted sequence and elapsed media tick from source coordinates,
  advancing sequence only after known successful submission.
- Preserve latest-only disposable frames and capture independence on all failures.
- Consume med_ex ~> 0.4.0 and providers ~> 0.3.0; publish directly with Mix
  without shipping `mix.lock` in the Hex tarball.

### Hardening

- Install host OTP log-privacy filtering aligned with `MedFabric.*` ownership,
  normalize expected startup failures and refresh third-party dependency floors
  (`bandit ~> 1.15`, `plug ~> 1.20.4`, `credo`, `dialyxir`, `ex_doc`).

### Tests and documentation

- Add capability, expiry, frame validation, log privacy, ownership and bounded
  peer tests.
- Document isolated runtime, direct/relay media and raw-integrity qualification;
  formal native and soak gates remain mandatory before publication.

## [0.2.1] - 2026-11-26

- Align release qualification and dependency floors with MedEx 0.3.1 and its 0.2.1 providers.

## [0.2.0] - 2026-11-25

- Reject empty shared credentials and invalid environment-configured listener ports.
- Correct native build prerequisites and document runtime configuration for host projects.
- Support file-based deployment configuration (`/etc/med_fabric/preview.json`).
- Adopt `med_ex_opus ~> 0.2.0` (Port-isolated C11 `libopus` encoder, removing Membrane/Ratio dependency conflicts), `med_ex_rtc ~> 0.2.0`, and `med_ex ~> 0.3.0`.

## [0.1.1] - 2026-11-25

- Close peers on encoder failure and preserve startup backpressure.
- Require MedEx 0.2.1.

All notable changes to `mf_preview` will be documented in this file.

## [0.1.0] - 2026-11-24

- Initial Hex release of the isolated Med Fabric Preview service (`mf_preview`).
- Loopback authenticated HTTP feed (`POST /feed`) with latest-only ETS buffering and 200 ms staleness guard.
- Signed short-lived viewer signaling (`offer`, `status`, `close`) backed by `med_ex_opus ~> 0.1.0` and `med_ex_rtc ~> 0.1.0`.
- Runs in a dedicated BEAM process isolated from Exam's database, enrollment keys, and authoritative clinical artifacts.

[0.3.0]: https://github.com/nshkrdotcom/med_fabric/compare/mf_preview-v0.2.1...mf_preview-v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/med_fabric/compare/mf_preview-v0.2.0...mf_preview-v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/med_fabric/compare/mf_preview-v0.1.1...mf_preview-v0.2.0
[0.1.1]: https://github.com/nshkrdotcom/med_fabric/compare/mf_preview-v0.1.0...mf_preview-v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/med_fabric/releases/tag/mf_preview-v0.1.0
