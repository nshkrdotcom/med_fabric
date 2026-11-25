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
for authorized clinicians.

Review intervals can cross adjacent storage chunks within a single configuration
epoch. They cannot cover missing samples. A complete-capture decision records
the selected interval from a defect-free capture. An interrupted stream retains
its verified prefix and terminal reason.

The native synthetic qualification covers 60-second paired recordings. The
writer's 1,800-second limit is a resource cap. Capture, finalization and review
at longer durations depend on the target storage and service load.
