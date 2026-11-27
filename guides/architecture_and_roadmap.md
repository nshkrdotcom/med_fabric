# Architecture and ownership

Exam owns authenticated clinical composition. Domain owns deterministic native
validity/decision plans. Store owns SQL, transactions and durable identities with
explicit db/tx arguments. Interop owns checked FHIR mapping and remote effects
after clinical commit. None may silently take another owner's responsibility.

Handheld owns source production and durable local spool. The browser owns bounded
volatile source buffers in its current page. The SDK journal is authoritative for
server waveform progress; Store keeps a verified projection. Final evidence is an
immutable manifest with verified indexes/events, not live monitoring or a UI cache.

| Dimension | Authority |
|---|---|
| Grant/session/membership and current generation | Store |
| Attempt/fence reservation | Store |
| Source coverage and pending bytes | Device spool/current browser page |
| Durable waveform prefix and terminal integrity | SDK journal/index |
| Frozen technical acquisition evidence | Verified manifest |
| Native acceptance and observations | Atomic Domain/Store result |
| Delivery intent/attempt history | Store outbox |
| External confirmation | Strict matching remote observation plus safe confirmation |
| Optional monitoring | Disposable sidecar peers/slots only |

A per-stream effect gate is acquired before SQL locks. Keep it until actual
storage work is quiescent, including after a database backend crash. Lock order
is encounter, acquisition/authority, generation/session, attempts in stable
stream order, evidence/review, observation/intent. No network runs under those
locks. Revocation closes new admission; an already admitted filesystem effect
may settle and its bytes must be preserved.

Native acceptance is independent of mapping/configuration/destination. Manual
pulse has immutable manual evidence, not a dummy stream. Browser microphone,
paired audio/ECG and PLX share source-neutral review; PLX has no waveform index.
One active acquisition per encounter/profile permits distinct profiles together.

Build one mf_exam Weld monolith and two direct Mix apps. The optional sidecar is
a separate BEAM with concrete providers. Keep no second recorder, provider facade,
backend, generalized workflow engine or private-core publication.
