# Changelog

## 0.1.1 - 2026-11-25

- Replay multi-sequence gaps and stop production on verified premature terminal receipts.
- Own live per-stream watermarks in `Spool`, replace per-ACK directory scans with O(k) sequence-range reclamation, recover past reclaimed prefixes from validated persisted receipts, and negotiate up to 15-frame pipelined credit with single-credit fallback.
- Use `MedEx.ControlInterlock.device_decide/3` for command replay and epoch decisions while bounding the persisted result cache. Check the synthetic PLXS adapter mapping with `MedEx.Serialization.measurement/1`.
- Require MedEx 0.2.1.

All notable changes to `mf_handheld` will be documented in this file.

## 0.1.0 - 2026-11-24

- Initial Hex release of the standalone Med Fabric Handheld client (`mf_handheld`).
- Synthetic RDP1 acoustic/ECG and PLXS pulse-oximetry peripheral drivers with local clock and command journal.
- Bounded disk spool with Linux `flock`/fsync durability and resumable Gun WSS/TLS transport against `mf_exam`.
- Consumes public `med_ex ~> 0.2.0` from Hex with standalone `mix.exs`, HexDocs guides, and Mix release support.
