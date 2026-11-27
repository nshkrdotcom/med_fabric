# Handheld integration

Exam 0.3.0 and Handheld 0.3.0 speak `medex.acquisition.v2`, API revision 2.
The binary sample frame remains MEX1 revision 1 with its fixed 48-byte header.
No older control, schema, artifact or spool reader is retained.

## Admission and source identity

Enroll device credentials and grant a clinician-authorized encounter/profile/site
through explicit Store database operations. A TLS device control connection
admits the exact principal, boot identity, source descriptors and requested
profile. The allowed profiles are `paired_exam` (audio plus ECG) and
`plx_spot_check` (events only). Browser creation is independently authorized but
then enters the same acquisition protocol. One active acquisition per encounter
and profile is enforced transactionally; distinct allowed profiles may coexist.

The host returns a lease/generation bound to a fresh connection incarnation.
Every consequential response carries its operation identity and complete binding.
A durable receipt is historical evidence; it cannot renew a lease or make a
superseded socket current. Heartbeat/command grants use the outstanding nonce and
poll-start monotonic budget. The independent heartbeat path continues while a
waveform uploader stalls.

## Durable waveform path

The common `MedFabric.Exam.AcquisitionIngress` owns each stream effect gate. It
takes that gate before the Store transaction/advisory scope, reserves a fenced
attempt, recovers the actual predecessor and uses the sole MedEx StreamWriter.
Only explicit manual checkpoints within current host authority advance durable
acknowledgment. Unknown journal/SQL outcomes retire the writer and require actual
worker and OS quiescence before a successor is admitted.

Both source and host obey negotiated slot/byte credit. Maximum-payload frames,
source gaps and exact retries consume their defined resources. The Handheld
spool persists exact acknowledgment bytes before deleting covered records;
reclaim work is proportional to newly covered records. An invalid receipt cannot
partially delete or release anything. Reconnect verifies retained contiguous
coverage, actual receipt progression and the authenticated new binding before
replacing old local state.

## Measurement events and clinical selection

PLX transport contains canonical SDK `MeasurementEvent` values. Domain validates
the exact raw indication, metric values, device status, measurement time,
availability time and source provenance. There is no empty waveform invented
for a spot-check collection. The manifest freezes the event inventory.

A clinician chooses the exact event and one or both eligible metrics. Native
acceptance of all selected metrics is atomic: an invalid second metric rolls
back the whole decision. A later mapping failure can block only delivery while
leaving the accepted native facts intact. SpO₂ uses exact decimal arithmetic and
the native 0–100 range; pulse is nonnegative and is not capped at 100. Unknown or
special values/status/time are not silently converted into eligible observations.

## Optional live monitoring and commands

The raw source owns recording bytes. Software monitor gain applies only to a
derived monitor branch. The bounded latest slot and monitor ledger may fail
without changing raw output. Commands record exact command ID/fingerprint, boot,
generation, epoch and application coordinates; a setting alone is not evidence
that a particular command ran. An uncertain outcome is recorded as unknown and
requires readback, not blind mutation replay.

Live ECG publication occurs after authoritative commit and tolerates missing or
replaced ETS state. Preview is a separate process with no database/artifact
credentials, one replaceable feed slot and bounded source/viewer resources. It
uses a short-lived actor/session/source capability and explicit fresh renewal.

## Qualification

Use the Handheld source/spool/transport/monitor tests, Exam common acquisition
integration tests and native driver. Cover revoked/replaced authority, malformed
control and frames, PostgreSQL loss before/after journal sync, delayed historical
ACK, checksum corruption, ACK/reclaim crash, terminal install recovery, source
reset/gaps and actual monitor kill/stall/trace. Run real service/TLS/browser/native
fault phases separately from both 1,740-second clean ext4 soaks. Keep exact bytes,
source hashes, clocks, bounds and reclaim metrics; never infer success from a
connected socket or a running process.
