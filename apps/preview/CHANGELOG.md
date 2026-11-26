# Changelog

## 0.2.1 — 2026-11-26

- Align release qualification and dependency floors with MedEx 0.3.1 and its 0.2.1 providers.

## 0.2.0 - 2026-11-25

- Reject empty shared credentials and invalid environment-configured listener ports.
- Correct native build prerequisites and document runtime configuration for host projects.
- Support file-based deployment configuration (`/etc/med_fabric/preview.json`).
- Adopt `med_ex_opus ~> 0.2.0` (Port-isolated C11 `libopus` encoder, removing Membrane/Ratio dependency conflicts), `med_ex_rtc ~> 0.2.0`, and `med_ex ~> 0.3.0`.

## 0.1.1 - 2026-11-25

- Close peers on encoder failure and preserve startup backpressure.
- Require MedEx 0.2.1.

All notable changes to `mf_preview` will be documented in this file.

## 0.1.0 - 2026-11-24

- Initial Hex release of the isolated Med Fabric Preview service (`mf_preview`).
- Loopback authenticated HTTP feed (`POST /feed`) with latest-only ETS buffering and 200 ms staleness guard.
- Signed short-lived viewer signaling (`offer`, `status`, `close`) backed by `med_ex_opus ~> 0.1.0` and `med_ex_rtc ~> 0.1.0`.
- Runs in a dedicated BEAM process isolated from Exam's database, enrollment keys, and authoritative clinical artifacts.
