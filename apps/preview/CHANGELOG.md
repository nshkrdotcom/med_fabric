# Changelog

## 0.1.1

- Close peers on encoder failure and preserve startup backpressure.
- Require MedEx 0.2.1.


All notable changes to `mf_preview` will be documented in this file.

## 0.1.0 - 2026-11-24

- Initial Hex release of the isolated Med Fabric Preview service (`mf_preview`).
- Loopback authenticated HTTP feed (`POST /feed`) with latest-only ETS buffering and 200 ms staleness guard.
- Signed short-lived viewer signaling (`offer`, `status`, `close`) backed by `med_ex_opus ~> 0.1.0` and `med_ex_rtc ~> 0.1.0`.
- Runs in a dedicated BEAM process isolated from Exam's database, enrollment keys, and authoritative clinical artifacts.
