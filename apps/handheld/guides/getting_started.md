# Getting started

Use an installed `mf_handheld ~> 0.3.0` consumer and the matching revision-2 Exam
release. A development checkout selects MedEx through the repository's single
`.mix_sources.json` mechanism. Published package dependencies remain normal,
bounded Hex requirements.

An example configuration, with operator-provisioned paths and enrolled identity:

```json
{
  "server": "wss://exam.example.test",
  "credential_file": "/etc/med_fabric/device-token",
  "ca_file": "/etc/med_fabric/exam-ca.pem",
  "device": "reference-device",
  "encounter": "encounter-1",
  "acquisition": "acquisition-1",
  "spool_root": "/var/lib/med_fabric/handheld",
  "spool_limit": 67108864,
  "seconds": 60,
  "seed": 7,
  "max_credit_frames": 15,
  "max_credit_bytes": 262144,
  "preview": false
}
```

The credential is a separate protected file, 16–4,096 bytes after trimming.
The endpoint must use WSS and its certificate must match the approved host.
Omitting `ca_file` uses the platform CA store; it does not disable verification.
Device, encounter and acquisition identifiers use bounded ASCII identifiers.
The host must have an active enrollment/grant for the source profile.

Invoke `MedFabric.Handheld.CLI.main/1` with `--config` and `--scenario paired_exam` or
`--scenario plx_spot_check`. The paired profile records separate audio and ECG
streams under one acquisition. PLX records discrete events and their final
inventory, without inventing waveform streams. Browser microphone production
belongs to Exam.

The first authenticated hello fixes descriptors and advertises API revision 2.
Every later connection receives a unique server-issued incarnation. An uploader
opens its own stream binding and receives a fully durable verified prefix.
Lease validity is measured from the start of the admission/heartbeat request;
delayed replies do not start a fresh local timer.

The reference oscillator uses actual observed synthetic packet coordinates,
source boot identity and declared timing uncertainty. Its declared fixture
calibration applies only to the simulator. Keep source files and reports for the
exact native test run; `status: complete` in `result.json` requires a verified
sealed host manifest, whereas `interrupted` preserves retained local evidence.
