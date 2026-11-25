# Changelog

## 0.1.1

- Replay multi-sequence gaps and stop production on verified premature terminal receipts.
- Require MedEx 0.2.1.

All notable changes to `mf_handheld` will be documented in this file.

## 0.1.0 - 2026-11-24

- Initial Hex release of the standalone Med Fabric Handheld client (`mf_handheld`).
- Synthetic RDP1 acoustic/ECG and PLXS pulse-oximetry peripheral drivers with local clock and command journal.
- Bounded disk spool with Linux `flock`/fsync durability and resumable Gun WSS/TLS transport against `mf_exam`.
- Consumes public `med_ex ~> 0.2.0` from Hex with standalone `mix.exs`, HexDocs guides, and Mix release support.
