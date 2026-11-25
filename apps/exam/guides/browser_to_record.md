# Browser to Record

The browser examination workflow pairs direct two-way clinician/patient
talkback with authoritative lossless WAV capture and atomic clinical export.

## Flow

1. **Encounter admission:** Patient and clinician sessions authenticate into an
   active encounter hosted by `MedFabric.ExamWeb.ExamLive`.
2. **Two-way talkback:** Patient and clinician browsers negotiate a direct
   WebRTC talkback call through `MedFabric.ExamWeb.TalkbackChannel`.
3. **Authoritative PCM capture:** The patient browser streams 48 kHz mono
   PCM16LE over `MedFabric.ExamWeb.PCMSocket`. `MedEx` finalizes the lossless
   WAV independently of any live preview path.
4. **Manual vital entry:** Clinicians can record manually entered pulse-rate
   observations alongside audio evidence (`MedFabric.Exam.pulse/4`).
5. **Review, acceptance & FHIR export:** Only finalized, verified acquisitions
   appear for review. `MedFabric.Exam.accept/4` verifies the artifact digest
   and commits clinical acceptance and its FHIR outbox intent in one PostgreSQL
   transaction. `MedFabric.Exam.deliver/4` performs conditional FHIR R4
   delivery (`If-None-Exist`) and confirms clinical fields on read-back.

## Optional Legacy In-VM Media Profile

The published Hex package depends only on base `:med_ex`. For source-checkout
browser tests that require in-VM Opus/WebRTC providers instead of the isolated
`mf_preview` sidecar, build and run with `MF_EXAM_LEGACY_MEDIA=1`.
