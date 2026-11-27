# Med Fabric

Med Fabric 0.3.0 coordinates source-preserving examination acquisition, native
clinical review and independent delivery. It uses MedEx 0.4.0 technical contracts
and protocol revision 2. Browser microphone and paired waveform inputs share
one writer/journal/manifest path; PLX is event-only, and manual pulse is native
clinical evidence awaiting an explicit clinician decision.

| Published package | Version | Construction | Purpose |
|---|---|---|---|
| mf_exam | 0.3.0 | Weld monolith | Clinical host plus private Domain/Store/Interop |
| mf_handheld | 0.3.0 | Direct Mix | Device source, bounded durable spool and uploader |
| mf_preview | 0.3.0 | Direct Mix | Optional isolated Opus/WebRTC monitoring |

Exam and Handheld require `med_ex ~> 0.4.0` and no media providers. Preview requires
the base and concrete `med_ex_opus ~> 0.3.0`/`med_ex_rtc ~> 0.3.0`. Domain, Store
and Interop are private source components of the Exam artifact, never public
packages. Exactly two Weld artifacts and four direct Mix packages span both repos.

## Runtime behavior

Exam derives device or patient authority at the transport boundary, reserves a
fence, and commits durable receipts before ACK. Clients match the current
connection incarnation; a historical ACK cannot renew permission. Unknown
filesystem/DB outcomes retire the writer and require positive effect quiescence
and verified recovery. Browser capture retains only bounded current-page buffers;
page death cannot claim offline continuity.

Pure Domain validates evidence and selections. One Store transaction commits a
native decision, immutable observations and export intent. Missing FHIR config,
unrepresentable mapping or network failure cannot undo valid acceptance. The
outbox independently pins identity/resource/destination and records blocked,
unresolved, retryable, conflict or confirmed outcomes with safe retry predicates.

Verified manifest/index/segment routes serve exact bounded bytes. Optional Preview
runs in another BEAM and cannot block recording/review. Direct browser talkback
has independent call authorization and cooperating-client renewal/teardown;
server signaling cannot forcibly stop established direct P2P media.

## Development

Use the pinned `.tool-versions` and Elixir ~> 1.20. Root Blitz orchestration covers
all three private core projects and all three apps, including Preview. Run each
project's formatter, warning-free compile, tests, Credo, Dialyzer and ExDoc in its
actual dependency context. Native browser/PostgreSQL/HAPI/Opus/RTC and detached
release tests are explicit additional lanes.

`.mix_sources.json` is the sole development source selector. Choose trusted paths,
exact Git refs or ordinary/signed registry packages for the three upstream SDK
packages. Internal component paths stay fixed. Example for a sibling checkout:

```json
{
  "med_ex": {"path": "../med_ex"},
  "med_ex_opus": {"path": "../med_ex/extensions/med_ex_opus"},
  "med_ex_rtc": {"path": "../med_ex/extensions/med_ex_rtc"}
}
```

Source contexts isolate deps/build/locks; detached packages use normal Hex
requirements. Do not fabricate candidate lock checksums. See the
[release guide](guides/releasing_exam.md) for source freeze and exact artifacts.

## Operations

Provision fresh revision-2 DB, evidence and spool namespaces. Bind immutable
deployment UUID to DB and root, enforce exclusive local service ownership and
verify installed SQL/assets before listener activation. Preserve prior evidence
in approved checksummed offline archives. Restoring an older backup requires
accounting for later irreversible evidence and external writes; otherwise remain
non-writable. No automatic destructive reset or writable restore clone.

Synthetic/reference qualification proves software behavior, not sensor
calibration or clinical readiness. See the [failure matrix](guides/failure_matrix.md),
[clinical boundary](guides/security_and_clinical_boundary.md),
[private core guide](guides/clinical_core.md), and package READMEs.
