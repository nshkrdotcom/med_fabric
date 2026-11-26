# Handheld Integration

`mf_exam` admits enrolled `mf_handheld` clients over TLS WebSockets
(`MedFabric.ExamWeb.DeviceSocket`) and persists resumable waveform and
spot-check acquisitions.

## Paired Acoustic & ECG Examination

- Exam validates the device credential and encounter grant before admitting an
  acquisition (`MedFabric.Exam.DeviceIngress`).
- Incoming frames are persisted durably with explicit segment boundaries,
  discontinuity gaps, and clock-alignment uncertainty bounds
  (`MedFabric.Exam.ClockObservations`).
- Clinicians inspect verified segments and play back authenticated audio slices
  via `MedFabric.ExamWeb.DeviceLive` and the segment playback endpoint.

## Pulse-Oximetry Spot Checks (PLXS)

- Replayed `device_spo2_v1` and `device_pulse_rate_v1` measurements preserve
  exact decimal mantissa/exponent values, measurement timestamps, peripheral
  `Device/...` references, and event lineage.
- Clinicians can mark a collection unusable, request a repeat, or accept
  eligible metrics. Each accepted metric receives an independent, retryable
  HL7 FHIR R4 `Observation` delivery record (LOINC `2708-6` / UCUM `%` for SpO2,
  LOINC `8867-4` / UCUM `/min` for pulse rate).

## Live Monitoring via `mf_preview`

When `MF_PREVIEW_URL` and `MF_PREVIEW_CREDENTIAL_FILE` are configured,
`MedFabric.Exam.PreviewGateway` forwards validated monitor frames to the
isolated `mf_preview` sidecar and mints short-lived HMAC-SHA256 viewer tokens
for authorized clinicians. A relay restart drops buffered monitor frames while
capture and live ECG continue. Without a sidecar configured, Exam keeps live ECG
and skips starting the audio relay.

Review intervals can cross adjacent storage chunks within a single configuration
epoch. They cannot cover missing samples. A complete-capture decision records
the selected interval from a defect-free capture. An interrupted stream retains
its verified prefix and terminal reason.

The native synthetic qualification includes the 60-second paired
fault and recovery suite. A 29-minute ext4 soak on Fabric `90f796f` with
MedEx `48b8de2` captured and byte-verified 83,520,000 audio samples and
435,000 ECG samples, then completed synthetic review.

An encounter can have one active recording per profile, including during
finalization. A waveform exam and a spot check can therefore overlap.
Migration 007 tightens the earlier Phase 3A candidate policy. If that
candidate admitted overlapping recordings of the same profile, finish
or interrupt all but one through the application before applying 007.
Resolve overlapping profiles before downgrading to a schema that allows
only one active recording per encounter.

Exam accepts a supported nonzero source epoch at admission and checks
frames against the admitted epoch. Changing epochs within the same
acquisition is outside this contract. The synthetic clock fixture derives
its validity interval from the probe span. Physical clock drift and
multi-exam capacity require separate evidence.
