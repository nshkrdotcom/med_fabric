# Architecture

`mf_exam` composes four layers with strict ownership boundaries:

- **Domain (`MedFabric.Domain.*`):** Pure Elixir constructors and validation
  rules for audio waveform evidence (`audio_pcm16_wav`), manual pulse rates,
  and qualified device measurements—zero database or HTTP dependencies.
- **Store (`MedFabric.Store.*`):** Transactional PostgreSQL persistence for
  encounters, admitted attempts, sealed device manifests, clinician
  acceptances, and FHIR export outbox intents. Migrations live in `priv/sql/`
  and run under an advisory transaction lock.
- **Interop (`MedFabric.Interop.*`):** Maps accepted observations to HL7 FHIR
  R4 `Observation` payloads, preserves exact decimal precision in JSON, and
  delivers idempotently over HTTP using conditional create (`If-None-Exist`)
  with typed read-back confirmation.
- **Exam & Web (`MedFabric.Exam.*`, `MedFabric.ExamWeb.*`):** Phoenix +
  LiveView review UI, TLS device ingress, recording lifecycle/recovery, and
  optional loopback `mf_preview` gateway.

## Failure & Recovery Guarantees

- **Atomic acceptance:** Clinical acceptance and its FHIR outbox intent commit
  in a single PostgreSQL transaction.
- **Startup reconciliation:** Abandoned or interrupted recording attempts are
  reconciled on startup or next admission without corrupting finalized WAVs.
- **Preview isolation:** Live monitoring runs in a separate `mf_preview` BEAM
  with zero access to PostgreSQL, device keys, or clinical artifacts.
