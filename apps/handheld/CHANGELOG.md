# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-26

### Breaking changes

- Adopt revision-2 control and typed SDK receipt semantics with authenticated
  connection incarnations, verified handoff and persist-before-delete coverage.
- Account for exact frame/gap operations and encoded bytes within negotiated
  credit; checkpoint the final short batch before waiting to seal.
- Preserve one durable spool, explicit reconnect/drain lifecycle and incremental
  reclamation; reject incompatible or corrupt persisted source state.
- Keep raw spool persistence ahead of disposable monitoring; bound command
  admission and poll-start validity and validate the complete persisted ledger.
- Consume med_ex ~> 0.4.0 through the single explicit development selector or
  normal Hex dependencies. Publish as a direct Mix package.

### Tests and documentation

- Update receipt/reclaim, malformed state, asynchronous monitor and source tests.
- Document source continuity, retained evidence and native 29-minute qualification.

## [0.2.1] - 2026-11-26

- Keep distinct monitor batches captured in the same millisecond and preserve unread audio across gap-only batches.
- Use MedEx receipt progression before verifying local spool coverage and reclaiming records.
- Isolate local monitor processing from authoritative paired capture. Durable spool batches, upload and operator stop continue through a stalled or failed monitor.

## [0.2.0] - 2026-11-25

- Align base SDK requirement to `med_ex ~> 0.3.0`.

## [0.1.1] - 2026-11-25

- Replay multi-sequence gaps and stop production on verified premature terminal receipts.
- Own live per-stream watermarks in `Spool`, replace per-ACK directory scans with O(k) sequence-range reclamation, recover past reclaimed prefixes from validated persisted receipts, and negotiate up to 15-frame pipelined credit with single-credit fallback.
- Use `MedEx.ControlInterlock.device_decide/3` for command replay and epoch decisions while bounding the persisted result cache. Check the synthetic PLXS adapter mapping with `MedEx.Serialization.measurement/1`.
- Keep staged waveform batches available to the spool after a caller timeout. Start capture and monitor workers only for paired exams.
- Require MedEx 0.2.1.

All notable changes to `mf_handheld` will be documented in this file.

## [0.1.0] - 2026-11-24

- Initial Hex release of the standalone Med Fabric Handheld client (`mf_handheld`).
- Synthetic RDP1 acoustic/ECG and PLXS pulse-oximetry peripheral drivers with local clock and command journal.
- Bounded disk spool with Linux `flock`/fsync durability and resumable Gun WSS/TLS transport against `mf_exam`.
- Consumes public `med_ex ~> 0.2.0` from Hex with standalone `mix.exs`, HexDocs guides, and Mix release support.

[0.3.0]: https://github.com/nshkrdotcom/med_fabric/compare/mf_handheld-v0.2.1...mf_handheld-v0.3.0
[0.2.1]: https://github.com/nshkrdotcom/med_fabric/compare/mf_handheld-v0.2.0...mf_handheld-v0.2.1
[0.2.0]: https://github.com/nshkrdotcom/med_fabric/compare/mf_handheld-v0.1.1...mf_handheld-v0.2.0
[0.1.1]: https://github.com/nshkrdotcom/med_fabric/compare/mf_handheld-v0.1.0...mf_handheld-v0.1.1
[0.1.0]: https://github.com/nshkrdotcom/med_fabric/releases/tag/mf_handheld-v0.1.0
